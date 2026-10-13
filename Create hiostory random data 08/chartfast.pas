unit ChartFast;

{
  Shared chart speed engine (HistoryRandomData, HistoryViewer, IPCChart).
  The same methods as in HistoryReader, but for growing data:

  * TSeriesIndex   level-of-detail min/max pyramid (blocks of 16, 256,
                   4096 ... samples, NaN ignored) + prefix sums of value,
                   value^2 and count. Build = whole data, Append = only the
                   new samples (live data), Clear = before replacing data.
  * TGapIndex      sorted list of the sample indexes that follow a gap
                   (Build / Append, binary search).
  * TXMap          sample index <-> pixel x for a time axis (sorted times)
                   or an index axis (equally spaced samples).
  * DrawDenseSeries  column rendering: one non-antialiased vertical span per
                   pixel column (line / steps / points, width, opacity).
  * TLayerCache    cached chart bitmap + signature; mouse moves only draw the
                   overlay on top of a copy.

  Data is passed as pointers (PDouble / PDateTime) so every program can use
  its own array types without copying.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, BGRABitmap, BGRABitmapTypes, ChartPainter;

type
  TFastDoubleArray = array of Double;
  TFastIntArray = array of Integer;

  { TSeriesIndex }

  TSeriesIndex = class
  private
    FSize: TFastIntArray;                     // block size of every level
    FMin, FMax: array of TFastDoubleArray;    // per level
    FUsed: TFastIntArray;                     // blocks in use per level
    FSum, FSum2: TFastDoubleArray;            // prefix sums, length >= Count+1
    FCnt: TFastIntArray;
    FCount: Integer;
    procedure AddLevel;
    procedure Put(Lv, Blk: Integer; V: Double);
  public
    procedure Clear;
    { index the first N values (replaces everything) }
    procedure Build(V: PDouble; N: Integer);
    { the data grew to N values: index V[Count..N-1] }
    procedure Append(V: PDouble; N: Integer);
    { min / max of the valid values A..B; False = only NaN / empty }
    function RangeMinMax(V: PDouble; A, B: Integer; out Mn, Mx: Double): Boolean;
    procedure RangeSums(A, B: Integer; out Sum, Sum2: Double; out Cnt: Integer);
    function Levels: Integer;
    function Bytes: Int64;
    property Count: Integer read FCount;
  end;

  { TGapIndex }

  TGapIndex = class
  private
    FIdx: TFastIntArray;
    FN, FCount: Integer;     // FN = gaps, FCount = samples indexed
    FGapDays: Double;
  public
    procedure Build(T: PDateTime; N: Integer; GapSeconds: Double);
    procedure Append(T: PDateTime; N: Integer);
    { first position in the list with a sample index >= I }
    function IndexFrom(I: Integer): Integer;
    { gaps between samples A..B }
    function Between(A, B: Integer): Integer;
    function Item(Pos: Integer): Integer;
    function Bytes: Int64;
    property Gaps: Integer read FN;
  end;

  TXMapKind = (xmTime, xmIndex);

  { sample index <-> x in pixels relative to the plot (0 .. PW) }
  TXMap = record
    Kind: TXMapKind;
    T: PDateTime;            // xmTime: sorted times
    N: Integer;              // samples
    Start, Span: Double;     // xmTime: TStart, span in days; xmIndex: first index, index span
    PW: Integer;
  end;

  { TLayerCache }

  TLayerCache = class
  private
    FBmp: TBGRABitmap;
    FSig: string;
    FHits, FMisses: Int64;
  public
    destructor Destroy; override;
    { True when the chart has to be rendered into Bitmap again (size or
      signature changed); the bitmap has the right size afterwards }
    function NeedsRender(W, H: Integer; const ASig: string): Boolean;
    procedure Invalidate;
    function Bytes: Int64;
    property Bitmap: TBGRABitmap read FBmp;
    property Hits: Int64 read FHits;
    property Misses: Int64 read FMisses;
  end;

function TimeXMap(T: PDateTime; N: Integer; TStart, Span: Double; PW: Integer): TXMap;
function IndexXMap(N: Integer; FirstIndex, IndexSpan: Double; PW: Integer): TXMap;
function XMapX(const M: TXMap; I: Integer): Double;
{ first sample index whose x is >= X (N when none) }
function XMapFirstAt(const M: TXMap; X: Double): Integer;

{ Column rendering of samples I0..I1 (may reach outside the view).
  Y = R.Bottom - (Value - AxisMin) / (AxisMax - AxisMin) * R.Height.
  Gaps may be nil (no gaps). Returns the number of pixel columns drawn. }
function DrawDenseSeries(P: TChartPainter; const R: TRect; const M: TXMap; V: PDouble;
  I0, I1: Integer; Idx: TSeriesIndex; Gaps: TGapIndex; AxisMin, AxisMax: Double;
  Color: TBGRAPixel; Width: Single; StepMode, PointMode: Boolean;
  var ColLo, ColHi: TFastDoubleArray): Integer;

implementation

{ ---------- TSeriesIndex ---------- }

procedure TSeriesIndex.Clear;
begin
  FSize := nil;
  FMin := nil;
  FMax := nil;
  FUsed := nil;
  FSum := nil;
  FSum2 := nil;
  FCnt := nil;
  FCount := 0;
end;

{ a new (coarser) level, built from the one below }
procedure TSeriesIndex.AddLevel;
var
  L, i, nb, k: Integer;
begin
  L := Length(FSize);
  SetLength(FSize, L + 1);
  SetLength(FMin, L + 1);
  SetLength(FMax, L + 1);
  SetLength(FUsed, L + 1);
  if L = 0 then FSize[0] := 16 else FSize[L] := FSize[L - 1] * 16;
  nb := (Max(FCount, 1) + FSize[L] - 1) div FSize[L];
  SetLength(FMin[L], nb + 16);
  SetLength(FMax[L], nb + 16);
  for i := 0 to High(FMin[L]) do
  begin
    FMin[L][i] := Infinity;
    FMax[L][i] := NegInfinity;
  end;
  FUsed[L] := 0;
  if L > 0 then
    for i := 0 to FUsed[L - 1] - 1 do
    begin
      k := i shr 4;
      if FMin[L - 1][i] < FMin[L][k] then FMin[L][k] := FMin[L - 1][i];
      if FMax[L - 1][i] > FMax[L][k] then FMax[L][k] := FMax[L - 1][i];
      if k + 1 > FUsed[L] then FUsed[L] := k + 1;
    end;
end;

procedure TSeriesIndex.Put(Lv, Blk: Integer; V: Double);
var
  i, Old: Integer;
begin
  if Blk >= Length(FMin[Lv]) then
  begin
    Old := Length(FMin[Lv]);
    SetLength(FMin[Lv], Blk * 2 + 16);
    SetLength(FMax[Lv], Blk * 2 + 16);
    for i := Old to High(FMin[Lv]) do
    begin
      FMin[Lv][i] := Infinity;
      FMax[Lv][i] := NegInfinity;
    end;
  end;
  if Blk + 1 > FUsed[Lv] then FUsed[Lv] := Blk + 1;
  if not IsNan(V) then
  begin
    if V < FMin[Lv][Blk] then FMin[Lv][Blk] := V;
    if V > FMax[Lv][Blk] then FMax[Lv][Blk] := V;
  end;
end;

procedure TSeriesIndex.Build(V: PDouble; N: Integer);
begin
  Clear;
  Append(V, N);
end;

procedure TSeriesIndex.Append(V: PDouble; N: Integer);
var
  i, Lv, Cap: Integer;
  X, S, S2: Double;
  C: Integer;
begin
  if N <= FCount then Exit;
  // prefix sums
  if Length(FSum) < N + 1 then
  begin
    Cap := Max(N + 1, Length(FSum) * 3 div 2 + 1024);
    SetLength(FSum, Cap);
    SetLength(FSum2, Cap);
    SetLength(FCnt, Cap);
  end;
  if FCount = 0 then
  begin
    FSum[0] := 0;
    FSum2[0] := 0;
    FCnt[0] := 0;
  end;
  S := FSum[FCount];
  S2 := FSum2[FCount];
  C := FCnt[FCount];
  for i := FCount to N - 1 do
  begin
    X := V[i];
    if not IsNan(X) then
    begin
      S := S + X;
      S2 := S2 + X * X;
      Inc(C);
    end;
    FSum[i + 1] := S;
    FSum2[i + 1] := S2;
    FCnt[i + 1] := C;
  end;
  // pyramid: existing levels get the new samples ...
  for i := FCount to N - 1 do
    for Lv := 0 to High(FSize) do
      Put(Lv, i div FSize[Lv], V[i]);
  FCount := N;
  // ... and coarser levels are added while the data outgrows them
  if Length(FSize) = 0 then
  begin
    if FCount > 16 then
    begin
      AddLevel;
      for i := 0 to FCount - 1 do Put(0, i shr 4, V[i]);
    end;
  end;
  while (Length(FSize) > 0) and (FSize[High(FSize)] < FCount) and
        (FSize[High(FSize)] <= MaxInt div 16) do
    AddLevel;
end;

function TSeriesIndex.RangeMinMax(V: PDouble; A, B: Integer; out Mn, Mx: Double): Boolean;
var
  i, Lv, Sz, Top: Integer;
  X: Double;
  Used: Boolean;
begin
  Mn := Infinity;
  Mx := NegInfinity;
  Top := High(FSize);
  i := Max(0, A);
  B := Min(B, FCount - 1);
  while i <= B do
  begin
    Used := False;
    for Lv := Top downto 0 do
    begin
      Sz := FSize[Lv];
      if (i mod Sz = 0) and (i + Sz - 1 <= B) then
      begin
        X := FMin[Lv][i div Sz];
        if X < Mn then Mn := X;
        X := FMax[Lv][i div Sz];
        if X > Mx then Mx := X;
        Inc(i, Sz);
        Used := True;
        Break;
      end;
    end;
    if not Used then
    begin
      X := V[i];
      if not IsNan(X) then
      begin
        if X < Mn then Mn := X;
        if X > Mx then Mx := X;
      end;
      Inc(i);
    end;
  end;
  Result := Mn <= Mx;
end;

procedure TSeriesIndex.RangeSums(A, B: Integer; out Sum, Sum2: Double; out Cnt: Integer);
begin
  Sum := 0;
  Sum2 := 0;
  Cnt := 0;
  A := Max(0, A);
  B := Min(B, FCount - 1);
  if B < A then Exit;
  Sum := FSum[B + 1] - FSum[A];
  Sum2 := FSum2[B + 1] - FSum2[A];
  Cnt := FCnt[B + 1] - FCnt[A];
end;

function TSeriesIndex.Levels: Integer;
begin
  Result := Length(FSize);
end;

function TSeriesIndex.Bytes: Int64;
var
  Lv: Integer;
begin
  Result := Int64(Length(FSum) + Length(FSum2)) * SizeOf(Double) +
    Int64(Length(FCnt)) * SizeOf(Integer);
  for Lv := 0 to High(FMin) do
    Inc(Result, Int64(Length(FMin[Lv]) + Length(FMax[Lv])) * SizeOf(Double));
end;

{ ---------- TGapIndex ---------- }

procedure TGapIndex.Build(T: PDateTime; N: Integer; GapSeconds: Double);
begin
  FIdx := nil;
  FN := 0;
  FCount := 0;
  FGapDays := GapSeconds / SecsPerDay;
  Append(T, N);
end;

procedure TGapIndex.Append(T: PDateTime; N: Integer);
var
  i: Integer;
begin
  for i := Max(1, FCount) to N - 1 do
    if T[i] - T[i - 1] > FGapDays then
    begin
      if FN >= Length(FIdx) then SetLength(FIdx, FN * 2 + 16);
      FIdx[FN] := i;
      Inc(FN);
    end;
  FCount := Max(FCount, N);
end;

function TGapIndex.IndexFrom(I: Integer): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  Lo := 0;
  Hi := FN;
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if FIdx[Mid] < I then Lo := Mid + 1 else Hi := Mid;
  end;
  Result := Lo;
end;

function TGapIndex.Between(A, B: Integer): Integer;
begin
  if B <= A then Exit(0);
  Result := IndexFrom(B + 1) - IndexFrom(A + 1);
end;

function TGapIndex.Item(Pos: Integer): Integer;
begin
  Result := FIdx[Pos];
end;

function TGapIndex.Bytes: Int64;
begin
  Result := Int64(Length(FIdx)) * SizeOf(Integer);
end;

{ ---------- TLayerCache ---------- }

destructor TLayerCache.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

function TLayerCache.NeedsRender(W, H: Integer; const ASig: string): Boolean;
begin
  if FBmp = nil then
    FBmp := TBGRABitmap.Create(W, H)
  else if (FBmp.Width <> W) or (FBmp.Height <> H) then
  begin
    FBmp.SetSize(W, H);
    FSig := '';
  end;
  Result := ASig <> FSig;
  if Result then
  begin
    FSig := ASig;
    Inc(FMisses);
  end
  else
    Inc(FHits);
end;

procedure TLayerCache.Invalidate;
begin
  FSig := '';
end;

function TLayerCache.Bytes: Int64;
begin
  if FBmp = nil then Result := 0
  else Result := Int64(FBmp.Width) * FBmp.Height * 4;
end;

{ ---------- x mapping ---------- }

function TimeXMap(T: PDateTime; N: Integer; TStart, Span: Double; PW: Integer): TXMap;
begin
  Result.Kind := xmTime;
  Result.T := T;
  Result.N := N;
  Result.Start := TStart;
  Result.Span := Span;
  Result.PW := PW;
end;

function IndexXMap(N: Integer; FirstIndex, IndexSpan: Double; PW: Integer): TXMap;
begin
  Result.Kind := xmIndex;
  Result.T := nil;
  Result.N := N;
  Result.Start := FirstIndex;
  Result.Span := Max(1e-9, IndexSpan);
  Result.PW := PW;
end;

function XMapX(const M: TXMap; I: Integer): Double;
begin
  if M.Kind = xmTime then
    Result := (M.T[I] - M.Start) / M.Span * M.PW
  else
    Result := (I - M.Start) / M.Span * M.PW;
end;

function XMapFirstAt(const M: TXMap; X: Double): Integer;
var
  Lo, Hi, Mid: Integer;
  T: Double;
begin
  if M.Kind = xmTime then
  begin
    T := M.Start + X / M.PW * M.Span;
    Lo := 0;
    Hi := M.N;
    while Lo < Hi do
    begin
      Mid := (Lo + Hi) div 2;
      if M.T[Mid] < T then Lo := Mid + 1 else Hi := Mid;
    end;
    Result := Lo;
  end
  else
    Result := EnsureRange(Ceil(M.Start + X / M.PW * M.Span - 1e-9), 0, M.N);
end;

{ ---------- column rendering ---------- }

function DrawDenseSeries(P: TChartPainter; const R: TRect; const M: TXMap; V: PDouble;
  I0, I1: Integer; Idx: TSeriesIndex; Gaps: TGapIndex; AxisMin, AxisMax: Double;
  Color: TBGRAPixel; Width: Single; StepMode, PointMode: Boolean;
  var ColLo, ColHi: TFastDoubleArray): Integer;
var
  PW, PH, j, k, c, c0, c1, ra, rb, a, b, a0, b0, ia, ib, gi, wpx, iv0, iv1: Integer;
  Mn, Mx, XPrev, YPrev, XC, YFirst, Half, Lo, Hi, YScale: Double;
  PrevOk: Boolean;

  function YOf(Value: Double): Double;
  begin
    Result := R.Bottom - (Value - AxisMin) * YScale;
  end;

  procedure AddSpan(Col: Integer; Y0, Y1: Double);
  begin
    if (Col < 0) or (Col >= PW) then Exit;
    if Y0 > Y1 then
    begin
      if Y1 < ColLo[Col] then ColLo[Col] := Y1;
      if Y0 > ColHi[Col] then ColHi[Col] := Y0;
    end
    else
    begin
      if Y0 < ColLo[Col] then ColLo[Col] := Y0;
      if Y1 > ColHi[Col] then ColHi[Col] := Y1;
    end;
  end;

  { the segment (XPrev, YPrev) -> (XTo, YTo) into column spans }
  procedure Connect(XTo, YTo: Double);
  var
    jj, jA, jB: Integer;
    x0, x1, y0, y1, XF, YF: Double;
  begin
    XF := XPrev;
    YF := YPrev;
    if (XTo - XF > 1e-9) and (XF < -2) then
    begin
      YF := YF + (YTo - YF) * (-2 - XF) / (XTo - XF);
      XF := -2;
    end;
    if (XTo - XF > 1e-9) and (XTo > PW + 2) then
    begin
      YTo := YF + (YTo - YF) * (PW + 2 - XF) / (XTo - XF);
      XTo := PW + 2;
    end;
    jA := Max(0, Floor(XF));
    jB := Min(PW - 1, Floor(XTo));
    if StepMode then
    begin
      for jj := jA to jB do AddSpan(jj, YF, YF);
      AddSpan(jB, YF, YTo);
      Exit;
    end;
    for jj := jA to jB do
    begin
      x0 := Max(jj, XF);
      x1 := Min(jj + 1, XTo);
      if x1 < x0 then Continue;
      if XTo - XF < 1e-9 then
      begin
        y0 := YF;
        y1 := YTo;
      end
      else
      begin
        y0 := YF + (YTo - YF) * (x0 - XF) / (XTo - XF);
        y1 := YF + (YTo - YF) * (x1 - XF) / (XTo - XF);
      end;
      AddSpan(jj, y0, y1);
    end;
  end;

begin
  Result := 0;
  PW := R.Width;
  PH := R.Height;
  if (PW <= 0) or (PH <= 0) or (I1 < I0) or (AxisMax = AxisMin) then Exit;
  YScale := PH / (AxisMax - AxisMin);
  if Length(ColLo) < PW then SetLength(ColLo, PW);
  if Length(ColHi) < PW then SetLength(ColHi, PW);
  for j := 0 to PW - 1 do
  begin
    ColLo[j] := 1e30;
    ColHi[j] := -1e30;
  end;
  iv0 := XMapFirstAt(M, 0);
  iv1 := XMapFirstAt(M, PW) - 1;

  // runs of samples between gaps
  ra := I0;
  if Gaps <> nil then gi := Gaps.IndexFrom(I0 + 1) else gi := 0;
  while ra <= I1 do
  begin
    rb := I1;
    if (Gaps <> nil) and (gi < Gaps.Gaps) and (Gaps.Item(gi) <= I1) then
      rb := Gaps.Item(gi) - 1;
    PrevOk := False;
    if ra < iv0 then
    begin
      k := Min(iv0 - 1, rb);
      while (k >= ra) and IsNan(V[k]) do Dec(k);
      if k >= ra then
      begin
        XPrev := XMapX(M, k);
        YPrev := YOf(V[k]);
        PrevOk := True;
      end;
    end;
    a0 := Max(ra, iv0);
    b0 := Min(rb, iv1);
    if a0 <= b0 then
    begin
      c0 := Max(0, Floor(XMapX(M, a0)));
      c1 := Min(PW - 1, Floor(XMapX(M, b0)));
      for c := c0 to c1 do
      begin
        a := Max(a0, XMapFirstAt(M, c));
        b := Min(b0, XMapFirstAt(M, c + 1) - 1);
        if a > b then Continue;
        if not Idx.RangeMinMax(V, a, b, Mn, Mx) then
        begin
          PrevOk := False;
          Continue;
        end;
        ia := a;
        while IsNan(V[ia]) do Inc(ia);
        ib := b;
        while IsNan(V[ib]) do Dec(ib);
        YFirst := YOf(V[ia]);
        XC := XMapX(M, ia);
        if PrevOk and not PointMode then Connect(XC, YFirst);
        AddSpan(c, YOf(Mx), YOf(Mn));
        XPrev := XMapX(M, ib);
        YPrev := YOf(V[ib]);
        PrevOk := True;
      end;
    end;
    if PrevOk and not PointMode and (rb > iv1) then
    begin
      k := Max(iv1 + 1, ra);
      while (k <= rb) and IsNan(V[k]) do Inc(k);
      if k <= rb then Connect(XMapX(M, k), YOf(V[k]));
    end;
    ra := rb + 1;
    Inc(gi);
  end;

  // one rectangle per column; width = horizontal + vertical dilation
  wpx := Max(1, Round(Width));
  Half := Max(0, (Width - 1) / 2);
  for j := 0 to PW - 1 do
  begin
    Lo := 1e30;
    Hi := -1e30;
    for k := j - (wpx - 1) div 2 to j + wpx div 2 do
      if (k >= 0) and (k < PW) then
      begin
        if ColLo[k] < Lo then Lo := ColLo[k];
        if ColHi[k] > Hi then Hi := ColHi[k];
      end;
    if Lo > Hi then Continue;
    P.FillRect(R.Left + j, Floor(Lo - Half), R.Left + j + 1, Floor(Hi + Half) + 1, Color);
    Inc(Result);
  end;
end;

end.
