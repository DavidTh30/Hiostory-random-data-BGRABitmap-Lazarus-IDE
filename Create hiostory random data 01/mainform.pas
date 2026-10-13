unit MainForm;

{
  History random data viewer
  --------------------------
  * 3 random data sets, one sample every 500 ms
  * On start, 3 hours of history are generated (21 600 samples per set)
    and written to history_data.csv. If the file already exists and is
    recent, it is loaded instead and the gap up to "now" is back-filled.
  * A timer keeps adding live samples (and appends them to the file).
  * Drawn with BGRABitmap. Scroll back with the scrollbar, mouse wheel
    or by dragging; Ctrl+wheel (or the combo box) changes the zoom.

  The three sets differ in height (base level / amplitude) and in
  smoothness (low-pass factor and noise):
    1. Low     - small amplitude, very smooth
    2. Medium  - medium amplitude, moderately smooth
    3. High    - large amplitude, rough / noisy
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DateUtils, Forms, Controls, Graphics, ExtCtrls,
  StdCtrls, BGRABitmap, BGRABitmapTypes;

const
  SampleMs = 500;
  SamplesPerSecond = 1000 div SampleMs;
  HistoryHours = 3;
  HistorySamples = HistoryHours * 3600 * SamplesPerSecond; // 21600
  SeriesCount = 3;
  DataFileName = 'history_data.csv';
  YAxisMax = 140;

type
  { Mean-reverting random walk followed by a low-pass filter.
    Smooth = filter factor (small = smoother), Jitter = raw noise. }
  TGenerator = record
    Name: string;
    Base, Amplitude, Smooth, Jitter: Double;
    Color: TBGRAPixel;
    Target, Value: Double;
  end;

  { TfrmMain }

  TfrmMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FTopPanel: TPanel;
    FBtnRegenerate, FBtnReload: TButton;
    FLblWindow, FLblStatus: TLabel;
    FCmbWindow: TComboBox;
    FChkFollow: TCheckBox;
    FPaintBox: TPaintBox;
    FScrollBar: TScrollBar;
    FTimer: TTimer;

    FGen: array[0..SeriesCount - 1] of TGenerator;
    FTimes: array of TDateTime;
    FData: array[0..SeriesCount - 1] of array of Double;
    FCount: Integer;
    FNextTime: TDateTime;

    FViewStart, FViewCount: Integer;
    FUpdatingScroll: Boolean;
    FHoverX: Integer;
    FDragging: Boolean;
    FDragX, FDragStart: Integer;
    FFS: TFormatSettings;
    FFilePath: string;

    procedure BuildUI;
    procedure InitGenerators;
    function NextValue(var G: TGenerator): Double;
    procedure ClearData;
    procedure AddSample(T: TDateTime);
    function SampleLine(Index: Integer): string;
    procedure AppendToFile(FromIndex: Integer);
    procedure GenerateHistory;
    function LoadFromFile: Boolean;
    procedure CatchUpToNow;

    function PlotRect: TRect;
    procedure ClampView;
    procedure UpdateScrollBar;
    procedure UpdateStatus;
    procedure ScrollTo(AStart: Integer);
    procedure SetWindowSeconds(Seconds: Integer);

    procedure TimerTick(Sender: TObject);
    procedure PaintBoxPaint(Sender: TObject);
    procedure ScrollBarChange(Sender: TObject);
    procedure CmbWindowChange(Sender: TObject);
    procedure ChkFollowChange(Sender: TObject);
    procedure BtnRegenerateClick(Sender: TObject);
    procedure BtnReloadClick(Sender: TObject);
    procedure PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseLeave(Sender: TObject);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

const
  WindowSeconds: array[0..6] of Integer = (60, 300, 600, 900, 1800, 3600, 10800);
  WindowNames: array[0..6] of string = ('1 min', '5 min', '10 min', '15 min',
    '30 min', '1 hour', '3 hours');
  TimeSteps: array[0..10] of Integer = (5, 10, 15, 30, 60, 120, 300, 600, 900,
    1800, 3600);
  DefaultWindowIndex = 2; // 10 min

{ TfrmMain }

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  Randomize;
  FFS := DefaultFormatSettings;
  FFS.DecimalSeparator := '.';
  FFilePath := ExtractFilePath(Application.ExeName) + DataFileName;
  FHoverX := -1;

  BuildUI;
  InitGenerators;
  FViewCount := WindowSeconds[DefaultWindowIndex] * SamplesPerSecond;

  // Reuse the existing file when it still reaches into the last 3 hours,
  // otherwise create a fresh 3-hour history.
  if not LoadFromFile then
    GenerateHistory
  else
    CatchUpToNow;

  FViewStart := FCount - FViewCount;
  ClampView;
  UpdateScrollBar;
  UpdateStatus;
  FTimer.Enabled := True;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  FTimer.Enabled := False;
end;

procedure TfrmMain.BuildUI;
var
  i: Integer;
begin
  DoubleBuffered := True;
  OnMouseWheel := @FormMouseWheel;

  FTopPanel := TPanel.Create(Self);
  FTopPanel.Parent := Self;
  FTopPanel.Align := alTop;
  FTopPanel.Height := 38;
  FTopPanel.BevelOuter := bvNone;

  FBtnRegenerate := TButton.Create(Self);
  FBtnRegenerate.Parent := FTopPanel;
  FBtnRegenerate.SetBounds(8, 6, 120, 26);
  FBtnRegenerate.Caption := 'Regenerate 3 h';
  FBtnRegenerate.OnClick := @BtnRegenerateClick;

  FBtnReload := TButton.Create(Self);
  FBtnReload.Parent := FTopPanel;
  FBtnReload.SetBounds(134, 6, 110, 26);
  FBtnReload.Caption := 'Reload file';
  FBtnReload.OnClick := @BtnReloadClick;

  FLblWindow := TLabel.Create(Self);
  FLblWindow.Parent := FTopPanel;
  FLblWindow.SetBounds(262, 11, 50, 20);
  FLblWindow.Caption := 'Window:';

  FCmbWindow := TComboBox.Create(Self);
  FCmbWindow.Parent := FTopPanel;
  FCmbWindow.SetBounds(316, 7, 90, 24);
  FCmbWindow.Style := csDropDownList;
  for i := Low(WindowNames) to High(WindowNames) do
    FCmbWindow.Items.Add(WindowNames[i]);
  FCmbWindow.ItemIndex := DefaultWindowIndex;
  FCmbWindow.OnChange := @CmbWindowChange;

  FChkFollow := TCheckBox.Create(Self);
  FChkFollow.Parent := FTopPanel;
  FChkFollow.SetBounds(422, 10, 90, 20);
  FChkFollow.Caption := 'Follow live';
  FChkFollow.Checked := True;
  FChkFollow.OnChange := @ChkFollowChange;

  FLblStatus := TLabel.Create(Self);
  FLblStatus.Parent := FTopPanel;
  FLblStatus.SetBounds(530, 11, 500, 20);

  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Parent := Self;
  FScrollBar.Kind := sbHorizontal;
  FScrollBar.Align := alBottom;
  FScrollBar.OnChange := @ScrollBarChange;

  FPaintBox := TPaintBox.Create(Self);
  FPaintBox.Parent := Self;
  FPaintBox.Align := alClient;
  FPaintBox.OnPaint := @PaintBoxPaint;
  FPaintBox.OnMouseDown := @PaintBoxMouseDown;
  FPaintBox.OnMouseMove := @PaintBoxMouseMove;
  FPaintBox.OnMouseUp := @PaintBoxMouseUp;
  FPaintBox.OnMouseLeave := @PaintBoxMouseLeave;

  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := SampleMs;
  FTimer.OnTimer := @TimerTick;
end;

{ ---------- data generation ---------- }

procedure TfrmMain.InitGenerators;

  procedure Setup(Idx: Integer; const AName: string; ABase, AAmp, ASmooth,
    AJitter: Double; AColor: TBGRAPixel);
  begin
    with FGen[Idx] do
    begin
      Name := AName;
      Base := ABase;
      Amplitude := AAmp;
      Smooth := ASmooth;
      Jitter := AJitter;
      Color := AColor;
      Target := ABase;
      Value := ABase;
    end;
  end;

begin
  //           name                 base  amp   smooth jitter color
  Setup(0, 'Set 1 (low, smooth)',   25,   6,   0.02,  0.05, BGRA(80, 200, 255));
  Setup(1, 'Set 2 (mid, medium)',   60,  15,   0.12,  0.60, BGRA(120, 230, 120));
  Setup(2, 'Set 3 (high, rough)',  100,  28,   0.70,  3.00, BGRA(255, 140, 60));
end;

function TfrmMain.NextValue(var G: TGenerator): Double;
begin
  // Random walk of the target, pulled back towards the base level
  G.Target := G.Target + RandG(0, G.Amplitude * 0.15);
  G.Target := G.Target + (G.Base - G.Target) * 0.02;
  G.Target := EnsureRange(G.Target, G.Base - G.Amplitude, G.Base + G.Amplitude);
  // Low-pass towards the target plus some raw noise
  G.Value := G.Value + G.Smooth * (G.Target - G.Value) + RandG(0, G.Jitter);
  G.Value := EnsureRange(G.Value, 0, YAxisMax);
  Result := G.Value;
end;

procedure TfrmMain.ClearData;
var
  s: Integer;
begin
  FCount := 0;
  SetLength(FTimes, 0);
  for s := 0 to SeriesCount - 1 do
    SetLength(FData[s], 0);
end;

procedure TfrmMain.AddSample(T: TDateTime);
var
  s, NewCap: Integer;
begin
  if FCount >= Length(FTimes) then
  begin
    NewCap := Max(HistorySamples + 1024, Length(FTimes) * 2);
    SetLength(FTimes, NewCap);
    for s := 0 to SeriesCount - 1 do
      SetLength(FData[s], NewCap);
  end;
  FTimes[FCount] := T;
  for s := 0 to SeriesCount - 1 do
    FData[s][FCount] := NextValue(FGen[s]);
  Inc(FCount);
end;

function TfrmMain.SampleLine(Index: Integer): string;
var
  s: Integer;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', FTimes[Index]);
  for s := 0 to SeriesCount - 1 do
    Result := Result + ';' + FormatFloat('0.000', FData[s][Index], FFS);
end;

procedure TfrmMain.AppendToFile(FromIndex: Integer);
var
  F: TFileStream;
  Buf: string;
  i: Integer;
begin
  if FromIndex >= FCount then Exit;
  Buf := '';
  for i := FromIndex to FCount - 1 do
    Buf := Buf + SampleLine(i) + LineEnding;
  try
    if FileExists(FFilePath) then
    begin
      F := TFileStream.Create(FFilePath, fmOpenReadWrite or fmShareDenyWrite);
      F.Seek(0, soEnd);
    end
    else
      F := TFileStream.Create(FFilePath, fmCreate);
    try
      F.WriteBuffer(Buf[1], Length(Buf));
    finally
      F.Free;
    end;
  except
    on E: Exception do
      FLblStatus.Caption := 'File write error: ' + E.Message;
  end;
end;

procedure TfrmMain.GenerateHistory;
var
  SL: TStringList;
  StartTime: TDateTime;
  i: Integer;
begin
  ClearData;
  InitGenerators;
  StartTime := IncMilliSecond(Now, -Int64(HistorySamples - 1) * SampleMs);
  for i := 0 to HistorySamples - 1 do
    AddSample(IncMilliSecond(StartTime, Int64(i) * SampleMs));
  FNextTime := IncMilliSecond(FTimes[FCount - 1], SampleMs);

  SL := TStringList.Create;
  try
    SL.Capacity := FCount + 1;
    SL.Add('Time;' + FGen[0].Name + ';' + FGen[1].Name + ';' + FGen[2].Name);
    for i := 0 to FCount - 1 do
      SL.Add(SampleLine(i));
    SL.SaveToFile(FFilePath);
  finally
    SL.Free;
  end;
end;

function TfrmMain.LoadFromFile: Boolean;
var
  SL, Parts: TStringList;
  i, s, NewCap: Integer;
  T: TDateTime;
begin
  Result := False;
  if not FileExists(FFilePath) then Exit;

  SL := TStringList.Create;
  Parts := TStringList.Create;
  try
    try
      SL.LoadFromFile(FFilePath);
    except
      Exit;
    end;
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;

    ClearData;
    NewCap := SL.Count + HistorySamples;
    SetLength(FTimes, NewCap);
    for s := 0 to SeriesCount - 1 do
      SetLength(FData[s], NewCap);

    for i := 1 to SL.Count - 1 do // line 0 = header
    begin
      Parts.DelimitedText := SL[i];
      if Parts.Count < SeriesCount + 1 then Continue;
      try
        T := ScanDateTime('yyyy-mm-dd hh:nn:ss.zzz', Parts[0]);
        FTimes[FCount] := T;
        for s := 0 to SeriesCount - 1 do
          FData[s][FCount] := StrToFloat(Parts[s + 1], FFS);
        Inc(FCount);
      except
        // skip malformed line
      end;
    end;
  finally
    Parts.Free;
    SL.Free;
  end;

  // Too old or empty -> caller generates a fresh history
  if (FCount = 0) or
     (MilliSecondsBetween(Now, FTimes[FCount - 1]) > Int64(HistorySamples) * SampleMs) then
  begin
    ClearData;
    Exit;
  end;

  // Continue the random walks from the last stored values
  for s := 0 to SeriesCount - 1 do
  begin
    FGen[s].Value := FData[s][FCount - 1];
    FGen[s].Target := FData[s][FCount - 1];
  end;
  FNextTime := IncMilliSecond(FTimes[FCount - 1], SampleMs);
  Result := True;
end;

procedure TfrmMain.CatchUpToNow;
var
  First: Integer;
begin
  First := FCount;
  while FNextTime <= Now do
  begin
    AddSample(FNextTime);
    FNextTime := IncMilliSecond(FNextTime, SampleMs);
  end;
  AppendToFile(First);
end;

{ ---------- view handling ---------- }

function TfrmMain.PlotRect: TRect;
begin
  Result := Rect(60, 34, FPaintBox.Width - 16, FPaintBox.Height - 28);
end;

procedure TfrmMain.ClampView;
begin
  FViewStart := EnsureRange(FViewStart, 0, Max(0, FCount - FViewCount));
end;

procedure TfrmMain.UpdateScrollBar;
var
  MaxV, Page: Integer;
begin
  FUpdatingScroll := True;
  try
    MaxV := Max(FCount - 1, 0);
    Page := Max(1, Min(FViewCount, MaxV + 1));
    FScrollBar.SetParams(FViewStart, 0, MaxV, Page);
    FScrollBar.LargeChange := Max(1, FViewCount div 2);
    FScrollBar.SmallChange := Max(1, FViewCount div 20);
  finally
    FUpdatingScroll := False;
  end;
end;

procedure TfrmMain.UpdateStatus;
var
  Shown: string;
begin
  if FCount = 0 then Exit;
  Shown := FormatDateTime('hh:nn:ss', FTimes[FViewStart]) + ' - ' +
    FormatDateTime('hh:nn:ss', FTimes[Min(FCount - 1, FViewStart + FViewCount - 1)]);
  FLblStatus.Caption := Format('%d samples / set   |   view %s   |   %s',
    [FCount, Shown, DataFileName]);
end;

procedure TfrmMain.ScrollTo(AStart: Integer);
begin
  FViewStart := AStart;
  ClampView;
  // Leaving the right edge turns "follow live" off, reaching it turns it on
  FChkFollow.OnChange := nil;
  FChkFollow.Checked := FViewStart >= FCount - FViewCount;
  FChkFollow.OnChange := @ChkFollowChange;
  UpdateScrollBar;
  UpdateStatus;
  FPaintBox.Invalidate;
end;

procedure TfrmMain.SetWindowSeconds(Seconds: Integer);
var
  Center: Integer;
begin
  if FChkFollow.Checked then
  begin
    FViewCount := Seconds * SamplesPerSecond;
    ScrollTo(FCount - FViewCount);
  end
  else
  begin
    Center := FViewStart + FViewCount div 2;
    FViewCount := Seconds * SamplesPerSecond;
    ScrollTo(Center - FViewCount div 2);
  end;
end;

{ ---------- events ---------- }

procedure TfrmMain.TimerTick(Sender: TObject);
var
  First: Integer;
begin
  First := FCount;
  CatchUpToNow;
  if FCount = First then Exit;
  if FChkFollow.Checked then
    FViewStart := FCount - FViewCount;
  ClampView;
  UpdateScrollBar;
  UpdateStatus;
  FPaintBox.Invalidate;
end;

procedure TfrmMain.ScrollBarChange(Sender: TObject);
begin
  if FUpdatingScroll then Exit;
  ScrollTo(FScrollBar.Position);
end;

procedure TfrmMain.CmbWindowChange(Sender: TObject);
begin
  SetWindowSeconds(WindowSeconds[FCmbWindow.ItemIndex]);
end;

procedure TfrmMain.ChkFollowChange(Sender: TObject);
begin
  if FChkFollow.Checked then
    ScrollTo(FCount - FViewCount);
end;

procedure TfrmMain.BtnRegenerateClick(Sender: TObject);
begin
  GenerateHistory;
  FChkFollow.Checked := True;
  ScrollTo(FCount - FViewCount);
end;

procedure TfrmMain.BtnReloadClick(Sender: TObject);
begin
  if LoadFromFile then
    CatchUpToNow
  else
    GenerateHistory;
  ScrollTo(FCount - FViewCount);
end;

procedure TfrmMain.PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then
  begin
    FDragging := True;
    FDragX := X;
    FDragStart := FViewStart;
  end;
end;

procedure TfrmMain.PaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  R: TRect;
begin
  FHoverX := X;
  if FDragging then
  begin
    R := PlotRect;
    if R.Width > 0 then
      ScrollTo(FDragStart - Round((X - FDragX) / R.Width * FViewCount));
  end
  else
    FPaintBox.Invalidate;
end;

procedure TfrmMain.PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  FDragging := False;
end;

procedure TfrmMain.PaintBoxMouseLeave(Sender: TObject);
begin
  FHoverX := -1;
  FPaintBox.Invalidate;
end;

procedure TfrmMain.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  Idx: Integer;
begin
  Handled := True;
  if ssCtrl in Shift then
  begin
    Idx := FCmbWindow.ItemIndex;
    if WheelDelta > 0 then Dec(Idx) else Inc(Idx);
    Idx := EnsureRange(Idx, 0, FCmbWindow.Items.Count - 1);
    if Idx <> FCmbWindow.ItemIndex then
    begin
      FCmbWindow.ItemIndex := Idx;
      SetWindowSeconds(WindowSeconds[Idx]);
    end;
  end
  else if WheelDelta > 0 then
    ScrollTo(FViewStart - Max(1, FViewCount div 10))
  else
    ScrollTo(FViewStart + Max(1, FViewCount div 10));
end;

{ ---------- drawing ---------- }

procedure TfrmMain.PaintBoxPaint(Sender: TObject);
const
  BackColor: TBGRAPixel = (blue: 32; green: 26; red: 24; alpha: 255);
var
  Bmp: TBGRABitmap;
  R: TRect;
  PW, PH, s, i, v, px, Step, LastIdx, A, B, Idx, LegendX: Integer;
  SpanSec, T0Sec, TSec: Double;
  Pts: array of TPointF;
  NPts: Integer;
  MinV, MaxV: Double;
  MinFirst: Boolean;
  Fmt, Txt: string;
  X: Single;

  function YOf(Value: Double): Single;
  begin
    Result := R.Bottom - Value / YAxisMax * PH;
  end;

  function XOf(Index: Double): Single;
  begin
    Result := R.Left + (Index - FViewStart) / Max(1, FViewCount - 1) * PW;
  end;

  procedure AddPt(AX, AY: Single);
  begin
    if NPts >= Length(Pts) then SetLength(Pts, NPts * 2 + 64);
    Pts[NPts] := PointF(AX, AY);
    Inc(NPts);
  end;

begin
  if (FPaintBox.Width < 100) or (FPaintBox.Height < 80) then Exit;
  Bmp := TBGRABitmap.Create(FPaintBox.Width, FPaintBox.Height, BackColor);
  try
    Bmp.FontName := 'Segoe UI';
    Bmp.FontHeight := 13;
    Bmp.FontQuality := fqSystemClearType;
    R := PlotRect;
    PW := R.Width;
    PH := R.Height;
    Bmp.FillRect(R.Left, R.Top, R.Right, R.Bottom, BGRA(16, 18, 22), dmSet);

    // Y grid
    v := 0;
    while v <= YAxisMax do
    begin
      Bmp.DrawHorizLine(R.Left, Round(YOf(v)), R.Right - 1, BGRA(50, 54, 62));
      Bmp.TextOut(R.Left - 6, YOf(v) - 8, IntToStr(v), BGRA(170, 170, 180), taRightJustify);
      Inc(v, 20);
    end;

    if FCount > 0 then
    begin
      LastIdx := Min(FCount - 1, FViewStart + FViewCount - 1);

      // X grid (time)
      SpanSec := (FViewCount - 1) / SamplesPerSecond;
      Step := TimeSteps[High(TimeSteps)];
      for i := Low(TimeSteps) to High(TimeSteps) do
        if TimeSteps[i] >= SpanSec / 8 then
        begin
          Step := TimeSteps[i];
          Break;
        end;
      if Step < 60 then Fmt := 'hh:nn:ss' else Fmt := 'hh:nn';
      T0Sec := FTimes[FViewStart] * SecsPerDay;
      TSec := Ceil(T0Sec / Step) * Step;
      while TSec <= T0Sec + SpanSec do
      begin
        X := XOf(FViewStart + (TSec - T0Sec) * SamplesPerSecond);
        Bmp.DrawVertLine(Round(X), R.Top, R.Bottom - 1, BGRA(50, 54, 62));
        Bmp.TextOut(X, R.Bottom + 5, FormatDateTime(Fmt, TSec / SecsPerDay),
          BGRA(170, 170, 180), taCenter);
        TSec := TSec + Step;
      end;

      // Series
      Bmp.ClipRect := R;
      for s := 0 to SeriesCount - 1 do
      begin
        NPts := 0;
        SetLength(Pts, 0);
        if FViewCount > PW * 2 then
        begin
          // More samples than pixels: draw min/max envelope per pixel column
          for px := 0 to PW - 1 do
          begin
            A := FViewStart + Int64(px) * FViewCount div PW;
            B := Min(FViewStart + Int64(px + 1) * FViewCount div PW - 1, LastIdx);
            if A > LastIdx then Break;
            MinV := FData[s][A];
            MaxV := MinV;
            MinFirst := True;
            for i := A + 1 to B do
            begin
              if FData[s][i] < MinV then begin MinV := FData[s][i]; MinFirst := False; end;
              if FData[s][i] > MaxV then begin MaxV := FData[s][i]; MinFirst := True; end;
            end;
            if MinFirst then
            begin
              AddPt(R.Left + px + 0.5, YOf(MinV));
              AddPt(R.Left + px + 0.5, YOf(MaxV));
            end
            else
            begin
              AddPt(R.Left + px + 0.5, YOf(MaxV));
              AddPt(R.Left + px + 0.5, YOf(MinV));
            end;
          end;
        end
        else
          for i := FViewStart to LastIdx do
            AddPt(XOf(i), YOf(FData[s][i]));
        SetLength(Pts, NPts);
        if NPts > 1 then
          Bmp.DrawPolyLineAntialias(Pts, FGen[s].Color, 1.5);
      end;
      Bmp.NoClip;

      // Hover cursor with values
      if (FHoverX >= R.Left) and (FHoverX < R.Right) and not FDragging then
      begin
        Idx := FViewStart + Round((FHoverX - R.Left) / PW * (FViewCount - 1));
        if (Idx >= 0) and (Idx < FCount) then
        begin
          X := XOf(Idx);
          Bmp.DrawLineAntialias(X, R.Top, X, R.Bottom, BGRA(255, 255, 255, 110), 1);
          Txt := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', FTimes[Idx]);
          for s := 0 to SeriesCount - 1 do
          begin
            Bmp.FillEllipseAntialias(X, YOf(FData[s][Idx]), 3.5, 3.5, FGen[s].Color);
            Txt := Txt + '    ' + FormatFloat('0.00', FData[s][Idx]);
          end;
          Bmp.TextOut(R.Right - 4, R.Top + 4, Txt, BGRA(240, 240, 240), taRightJustify);
        end;
      end;
    end;

    // Legend
    LegendX := R.Left;
    for s := 0 to SeriesCount - 1 do
    begin
      Bmp.FillRect(LegendX, 13, LegendX + 18, 17, FGen[s].Color, dmSet);
      Bmp.TextOut(LegendX + 24, 7, FGen[s].Name, BGRA(220, 220, 225));
      Inc(LegendX, 24 + Bmp.TextSize(FGen[s].Name).cx + 28);
    end;

    Bmp.Rectangle(R.Left, R.Top, R.Right, R.Bottom, BGRA(90, 95, 105), dmSet);
    Bmp.Draw(FPaintBox.Canvas, 0, 0, True);
  finally
    Bmp.Free;
  end;
end;

end.
