unit IPCChartForm;

{
  IPC chart client
  ----------------
  The connection, topics and protocol are handled by TIPCClientPanel
  (IPCClientPanel.pas, docked on the right, View > IPC client panel).
  This form is the chart: it gets the header, history blocks and live
  samples from the panel as events.

  * Default: the last 3 hours, then live samples.
  * Scrolling back past the oldest sample asks the server for more history.
  * Mouse: left drag in the chart = zoom box (right-to-left = undo zoom),
    right drag in the chart or left drag on the time axis = scroll,
    wheel = zoom time, Shift+wheel = scroll, on a Y axis:
    drag = move, wheel = zoom, double-click = auto range.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DateUtils, Forms, Controls, Graphics,
  ExtCtrls, StdCtrls, Menus, LCLType, BGRABitmap, BGRABitmapTypes,
  ChartPainter, IPCData, IPCClientPanel, DataGridPanel, ChartFast;

const
  MaxSeries = IPCMaxTopics;
  GapSeconds = 3.0;
  AxisWidth = 58;
  XAxisHeight = 26;
  MinSpanSeconds = 10;

type
  TDataKind = (dkBoolean, dkByte, dkInteger, dkDouble);

  TSeriesInfo = record
    Name: string;
    Kind: TDataKind;
    Color: TBGRAPixel;
    Visible: Boolean;
    AxisMin, AxisMax: Double;
    AxisUser: Boolean;
  end;

  { view before a zoom-box zoom, for undo }
  TZoomState = record
    ViewEnd, ViewSpan: TDateTime;
    Follow: Boolean;
    Series: array[0..MaxSeries - 1] of TSeriesInfo;
  end;

  { TfrmIPCChart }

  TfrmIPCChart = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    // UI
    FMainMenu: TMainMenu;
    FMnuSeries, FMnuFollow, FMnuPanel: TMenuItem;
    FTopPanel: TPanel;
    FCmbWindow: TComboBox;
    FChkFollow: TCheckBox;
    FBtnMore: TButton;
    FShpState: TShape;
    FLblStatus: TLabel;
    FPanel: TIPCClientPanel;
    FSplitter: TSplitter;
    FPaintBox: TPaintBox;
    FScrollBar: TScrollBar;
    FRepaint: TTimer;
    FStatusTick: Integer;

    // history requests made by the chart
    FHistForOlder: Boolean;
    FFirstBefore: TDateTime;
    FNoMoreHistory: Boolean;

    // data
    FSeriesCount: Integer;
    FSeries: array[0..MaxSeries - 1] of TSeriesInfo;
    FTimes: TIPCTimeArray;
    FData: TIPCValueArrays;
    FCount: Integer;
    FDirty: Boolean;

    // view
    FViewEnd, FViewSpan: TDateTime;
    FUpdatingScroll: Boolean;
    FHoverX, FHoverY: Integer;
    FDragging: Boolean;
    FDragX: Integer;
    FDragEnd: TDateTime;
    FAxisDrag, FAxisDragY: Integer;
    FAxisDragMin: Double;
    FSelecting: Boolean;
    FSelStart, FSelEnd: TPoint;
    FZoomStack: array of TZoomState;

    // data grid panel + grid lines
    FMnuDataGrid, FMnuGridLines: TMenuItem;
    FDataGrid: TDataGridPanel;
    FDataGridSplitter: TSplitter;
    FGridFirst: Integer;
    FShowGrid: Boolean;
    procedure UpdateDataGrid(Columns: Boolean = False);
    function DataGridCell(Row, Col: Integer): string;
    procedure DataGridRowDblClick(Sender: TObject; Row: Integer);
    procedure MnuDataGridClick(Sender: TObject);
    procedure MnuGridLinesClick(Sender: TObject);

  private
    // speed engine (ChartFast): LOD pyramid + prefix sums, gaps, layer cache
    FIdx: array[0..MaxSeries - 1] of TSeriesIndex;
    FGaps: TGapIndex;
    FLayer: TLayerCache;
    FFrame: TBGRABitmap;
    FColLo, FColHi: TFastDoubleArray;
    FDataVersion, FIndexVersion: Integer;
    FDense: array[0..MaxSeries - 1] of Boolean;
    FBenchDone: Boolean;
    procedure EnsureIndex;
    function ChartSignature(W, H: Integer): string;
    procedure DrawOverlay(P: TChartPainter);
    procedure RenderFrame(Dest: TBGRABitmap);
    procedure RunBench(Data: PtrInt);
  public
    destructor Destroy; override;
  private
    procedure BuildUI;
    procedure BuildSeriesMenu;

    // panel events
    procedure PanelConnected(Sender: TObject);
    procedure PanelHeader(Sender: TObject; const Header: string);
    procedure PanelHistory(Sender: TObject; const T: TIPCTimeArray;
      const V: TIPCValueArrays; N: Integer);
    procedure PanelSample(Sender: TObject; T: TDateTime; const V: array of Double);
    procedure PanelReset(Sender: TObject);
    procedure PanelHistoryChoice(Sender: TObject);
    procedure RequestHistory(Seconds: Integer; ForOlder: Boolean = False);
    procedure AddSample(T: TDateTime; const Vals: array of Double);
    procedure RepaintTick(Sender: TObject);

    // view
    function FirstTime: TDateTime;
    function LastTime: TDateTime;
    function ViewStart: TDateTime;
    function LowerBound(T: TDateTime): Integer;
    function NearestIndex(T: TDateTime): Integer;
    procedure AutoAxes;
    procedure SetView(AEnd: TDateTime; KeepFollow: Boolean = False);
    procedure SetSpan(ASpan: TDateTime; AnchorX: Integer = -1);
    procedure NeedHistoryFrom(T: TDateTime);
    procedure UpdateScrollBar;
    procedure UpdateStatus;
    procedure SyncWindowCombo;
    procedure PushZoom;
    procedure UndoZoom;
    procedure ZoomToRect(const Sel: TRect);
    function VisibleAxisCount: Integer;
    function AxisLeft(S: Integer): Integer;
    function AxisAt(X, Y: Integer): Integer;
    function PlotRect: TRect;
    function DisplayValue(S: Integer; V: Double): string;
    procedure DrawChart(P: TChartPainter; W, H: Integer);

    // events
    procedure PaintBoxPaint(Sender: TObject);
    procedure PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseLeave(Sender: TObject);
    procedure PaintBoxDblClick(Sender: TObject);
    procedure PaintBoxContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure ScrollBarChange(Sender: TObject);
    procedure BtnMoreClick(Sender: TObject);
    procedure CmbWindowChange(Sender: TObject);
    procedure ChkFollowChange(Sender: TObject);
    procedure MnuExitClick(Sender: TObject);
    procedure MnuFollowClick(Sender: TObject);
    procedure MnuAutoAxesClick(Sender: TObject);
    procedure MnuSeriesClick(Sender: TObject);
    procedure MnuPanelClick(Sender: TObject);
    procedure MnuUndoZoomClick(Sender: TObject);
    procedure MnuResetZoomClick(Sender: TObject);
  end;

var
  frmIPCChart: TfrmIPCChart;

implementation

{$R *.lfm}

function QueryPerformanceCounter(out Count: Int64): LongBool; stdcall; external 'kernel32.dll';
function QueryPerformanceFrequency(out Freq: Int64): LongBool; stdcall; external 'kernel32.dll';

const
  WindowSeconds: array[0..7] of Integer = (60, 600, 3600, 10800, 21600, 43200,
    86400, 259200);
  WindowNames: array[0..7] of string = ('1 min', '10 min', '1 hour', '3 hours',
    '6 hours', '12 hours', '1 day', '3 days');
  DefaultWindowIndex = 3;
  TimeSteps: array[0..16] of Integer = (1, 5, 10, 15, 30, 60, 120, 300, 600, 900,
    1800, 3600, 7200, 10800, 21600, 43200, 86400);
  KindNames: array[TDataKind] of string = ('Boolean', 'Byte', 'Integer', 'Double');
  BackColor: TBGRAPixel = (blue: 32; green: 26; red: 24; alpha: 255);

var
  Palette: array[0..MaxSeries - 1] of TBGRAPixel;

function NiceStep(Raw: Double): Double;
var
  Mag, Norm: Double;
begin
  if Raw <= 0 then Exit(1);
  Mag := Power(10, Floor(Log10(Raw)));
  Norm := Raw / Mag;
  if Norm <= 1 then Result := Mag
  else if Norm <= 2 then Result := 2 * Mag
  else if Norm <= 5 then Result := 5 * Mag
  else Result := 10 * Mag;
end;

function FormatAxisValue(V, Step: Double): string;
begin
  if Step >= 1 then Result := FormatFloat('0', V)
  else if Step >= 0.1 then Result := FormatFloat('0.0', V)
  else Result := FormatFloat('0.00', V);
end;

procedure SplitHeaderName(const Field: string; out AName: string; out AKind: TDataKind);
var
  P: Integer;
  K: TDataKind;
  TypeName: string;
begin
  AName := Trim(Field);
  AKind := dkDouble;
  P := LastDelimiter('[', AName);
  if (P > 0) and (AName <> '') and (AName[Length(AName)] = ']') then
  begin
    TypeName := Copy(AName, P + 1, Length(AName) - P - 1);
    for K := Low(TDataKind) to High(TDataKind) do
      if SameText(TypeName, KindNames[K]) then
      begin
        AKind := K;
        AName := Trim(Copy(AName, 1, P - 1));
        Break;
      end;
  end;
end;

{ TfrmIPCChart }

procedure TfrmIPCChart.FormCreate(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to MaxSeries - 1 do
    FIdx[i] := TSeriesIndex.Create;
  FGaps := TGapIndex.Create;
  FGaps.Build(nil, 0, GapSeconds);
  FLayer := TLayerCache.Create;
  Palette[0] := BGRA(80, 200, 255);
  Palette[1] := BGRA(120, 230, 120);
  Palette[2] := BGRA(255, 140, 60);
  Palette[3] := BGRA(230, 110, 230);
  Palette[4] := BGRA(255, 220, 90);
  Palette[5] := BGRA(120, 140, 255);
  Palette[6] := BGRA(255, 110, 110);
  Palette[7] := BGRA(200, 200, 200);

  FHoverX := -1;
  FAxisDrag := -1;
  FViewSpan := 3 * OneHour;
  FViewEnd := Now;
  BuildUI;

  // IPCChart.exe [host [port]] [/bench]
  if (ParamCount >= 1) and (ParamStr(1)[1] <> '/') then FPanel.Host := ParamStr(1);
  if (ParamCount >= 2) and (ParamStr(2)[1] <> '/') then
    FPanel.Port := StrToIntDef(ParamStr(2), IPCDefaultPort);

  FRepaint.Enabled := True;
  FPanel.Connect;
end;

procedure TfrmIPCChart.FormDestroy(Sender: TObject);
begin
  FRepaint.Enabled := False;
end;

destructor TfrmIPCChart.Destroy;
var
  i: Integer;
begin
  inherited Destroy;
  for i := 0 to MaxSeries - 1 do
    FreeAndNil(FIdx[i]);
  FreeAndNil(FGaps);
  FreeAndNil(FLayer);
  FreeAndNil(FFrame);
end;

procedure TfrmIPCChart.BuildUI;
var
  MFile, MView, MPanel: TMenuItem;
  i: Integer;

  function AddItem(AParent: TMenuItem; const ACaption: string;
    AHandler: TNotifyEvent; AShortCut: TShortCut = 0): TMenuItem;
  begin
    Result := TMenuItem.Create(FMainMenu);
    Result.Caption := ACaption;
    Result.OnClick := AHandler;
    Result.ShortCut := AShortCut;
    AParent.Add(Result);
  end;

begin
  DoubleBuffered := True;
  OnMouseWheel := @FormMouseWheel;

  FMainMenu := TMainMenu.Create(Self);
  Menu := FMainMenu;
  MFile := TMenuItem.Create(FMainMenu);
  MFile.Caption := '&File';
  FMainMenu.Items.Add(MFile);
  AddItem(MFile, 'E&xit', @MnuExitClick, ShortCut(Ord('Q'), [ssCtrl]));
  MView := TMenuItem.Create(FMainMenu);
  MView.Caption := '&View';
  FMainMenu.Items.Add(MView);
  MPanel := TMenuItem.Create(FMainMenu);
  MPanel.Caption := '&Panel';
  FMainMenu.Items.Add(MPanel);
  FMnuDataGrid := AddItem(MPanel, '&Data grid', @MnuDataGridClick, ShortCut(Ord('T'), [ssCtrl]));
  FMnuGridLines := AddItem(MPanel, 'Grid &lines', @MnuGridLinesClick);
  FMnuGridLines.Checked := True;
  FShowGrid := True;
  AddItem(MPanel, '-', nil);
  FMnuPanel := AddItem(MPanel, '&IPC client panel', @MnuPanelClick, ShortCut(Ord('I'), [ssCtrl]));
  FMnuPanel.Checked := True;
  FMnuFollow := AddItem(MView, '&Follow live', @MnuFollowClick, ShortCut(Ord('L'), [ssCtrl]));
  FMnuFollow.Checked := True;
  AddItem(MView, '-', nil);
  AddItem(MView, '&Undo zoom', @MnuUndoZoomClick, ShortCut(Ord('Z'), [ssCtrl]));
  AddItem(MView, 'Reset &zoom', @MnuResetZoomClick, ShortCut(Ord('0'), [ssCtrl]));
  AddItem(MView, '&Auto Y axes', @MnuAutoAxesClick, ShortCut(Ord('R'), [ssCtrl]));
  AddItem(MView, '-', nil);
  FMnuSeries := AddItem(MView, '&Data sets', nil);

  // chart toolbar
  FTopPanel := TPanel.Create(Self);
  FTopPanel.Parent := Self;
  FTopPanel.Align := alTop;
  FTopPanel.Height := 36;
  FTopPanel.BevelOuter := bvNone;

  with TLabel.Create(Self) do
  begin
    Parent := FTopPanel;
    SetBounds(10, 10, 50, 20);
    Caption := 'Window';
  end;
  FCmbWindow := TComboBox.Create(Self);
  FCmbWindow.Parent := FTopPanel;
  FCmbWindow.SetBounds(60, 6, 84, 24);
  FCmbWindow.Style := csDropDownList;
  for i := Low(WindowNames) to High(WindowNames) do
    FCmbWindow.Items.Add(WindowNames[i]);
  FCmbWindow.ItemIndex := DefaultWindowIndex;
  FCmbWindow.OnChange := @CmbWindowChange;

  FChkFollow := TCheckBox.Create(Self);
  FChkFollow.Parent := FTopPanel;
  FChkFollow.SetBounds(156, 9, 90, 20);
  FChkFollow.Caption := 'Follow live';
  FChkFollow.Checked := True;
  FChkFollow.OnChange := @ChkFollowChange;

  FBtnMore := TButton.Create(Self);
  FBtnMore.Parent := FTopPanel;
  FBtnMore.SetBounds(250, 5, 152, 26);
  FBtnMore.Caption := 'Request older data';
  FBtnMore.Hint := 'Ask the server for one more window of history' + LineEnding +
    '(happens automatically when you scroll back)';
  FBtnMore.ShowHint := True;
  FBtnMore.OnClick := @BtnMoreClick;

  FShpState := TShape.Create(Self);
  FShpState.Parent := FTopPanel;
  FShpState.Shape := stCircle;
  FShpState.SetBounds(414, 11, 14, 14);
  FLblStatus := TLabel.Create(Self);
  FLblStatus.Parent := FTopPanel;
  FLblStatus.SetBounds(434, 10, 900, 20);

  // IPC client panel on the right
  FPanel := TIPCClientPanel.Create(Self);
  FPanel.Parent := Self;
  FPanel.Align := alRight;
  FPanel.Width := 400;
  FPanel.OnConnected := @PanelConnected;
  FPanel.OnHeader := @PanelHeader;
  FPanel.OnHistory := @PanelHistory;
  FPanel.OnSample := @PanelSample;
  FPanel.OnReset := @PanelReset;
  FPanel.OnHistoryChoice := @PanelHistoryChoice;

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align := alRight;
  FSplitter.Left := FPanel.Left - 5;

  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Parent := Self;
  FScrollBar.Kind := sbHorizontal;
  FScrollBar.Align := alBottom;
  FScrollBar.OnChange := @ScrollBarChange;

  FDataGrid := TDataGridPanel.Create(Self);
  FDataGrid.Parent := Self;
  FDataGrid.Align := alBottom;
  FDataGrid.Height := 220;
  FDataGrid.Visible := False;
  FDataGrid.OnGetCell := @DataGridCell;
  FDataGrid.OnRowDblClick := @DataGridRowDblClick;
  FDataGridSplitter := TSplitter.Create(Self);
  FDataGridSplitter.Parent := Self;
  FDataGridSplitter.Align := alBottom;
  FDataGridSplitter.Visible := False;

  FPaintBox := TPaintBox.Create(Self);
  FPaintBox.Parent := Self;
  FPaintBox.Align := alClient;
  FPaintBox.OnPaint := @PaintBoxPaint;
  FPaintBox.OnMouseDown := @PaintBoxMouseDown;
  FPaintBox.OnMouseMove := @PaintBoxMouseMove;
  FPaintBox.OnMouseUp := @PaintBoxMouseUp;
  FPaintBox.OnMouseLeave := @PaintBoxMouseLeave;
  FPaintBox.OnDblClick := @PaintBoxDblClick;
  FPaintBox.OnContextPopup := @PaintBoxContextPopup;

  FRepaint := TTimer.Create(Self);
  FRepaint.Enabled := False;
  FRepaint.Interval := 100;
  FRepaint.OnTimer := @RepaintTick;
end;

procedure TfrmIPCChart.BuildSeriesMenu;
var
  s: Integer;
  Item: TMenuItem;
begin
  UpdateDataGrid(True);
  FMnuSeries.Clear;
  for s := 0 to FSeriesCount - 1 do
  begin
    Item := TMenuItem.Create(FMainMenu);
    Item.Caption := Format('Y%d: %s [%s]', [s + 1, FSeries[s].Name, KindNames[FSeries[s].Kind]]);
    Item.Checked := FSeries[s].Visible;
    Item.Tag := s;
    Item.OnClick := @MnuSeriesClick;
    FMnuSeries.Add(Item);
  end;
end;

{ ---------- panel events ---------- }

procedure TfrmIPCChart.RequestHistory(Seconds: Integer; ForOlder: Boolean);
begin
  FHistForOlder := ForOlder and (FCount > 0);
  FFirstBefore := FirstTime;
  if not ForOlder then
    FNoMoreHistory := False;
  FPanel.RequestHistory(Seconds);
  UpdateStatus;
end;

procedure TfrmIPCChart.PanelConnected(Sender: TObject);
begin
  if FCount > 0 then
    // reconnected: at least what we already show, plus the time we were away
    RequestHistory(Max(FPanel.HistorySeconds, Ceil((LastTime - FirstTime) * SecsPerDay) +
      Ceil((Now - LastTime) * SecsPerDay) + 5))
  else
    RequestHistory(FPanel.HistorySeconds);
end;

procedure TfrmIPCChart.PanelHeader(Sender: TObject; const Header: string);
var
  Parts: TStringList;
  s, NewCount: Integer;
  NewName: string;
  NewKind: TDataKind;
  CountChanged: Boolean;
begin
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Header;
    NewCount := Min(MaxSeries, Parts.Count - 1);
    CountChanged := NewCount <> FSeriesCount;
    for s := 0 to NewCount - 1 do
    begin
      SplitHeaderName(Parts[s + 1], NewName, NewKind);
      if NewName = '' then NewName := 'Set ' + IntToStr(s + 1);
      if s >= FSeriesCount then
      begin
        FSeries[s].Visible := True;
        FSeries[s].AxisUser := False;
        FSeries[s].Color := Palette[s];
      end;
      if FSeries[s].Kind <> NewKind then
        FSeries[s].AxisUser := False;
      FSeries[s].Name := NewName;
      FSeries[s].Kind := NewKind;
    end;
    FSeriesCount := NewCount;
    if CountChanged then
    begin
      FCount := 0;      // different set count: old samples do not fit
      Inc(FDataVersion);
    end;
  finally
    Parts.Free;
  end;
  BuildSeriesMenu;
  AutoAxes;
  FPaintBox.Invalidate;
end;

{ A history block replaces the data; live samples received meanwhile are
  newer and stay. }
procedure TfrmIPCChart.PanelHistory(Sender: TObject; const T: TIPCTimeArray;
  const V: TIPCValueArrays; N: Integer);
var
  KeepT: TIPCTimeArray;
  KeepV: TIPCValueArrays;
  KeepN, i, s, First: Integer;
  Vals: array[0..MaxSeries - 1] of Double;
begin
  First := FCount;
  if N > 0 then
    First := LowerBound(T[N - 1] + OneMillisecond / 2);
  KeepN := FCount - First;
  SetLength(KeepT, Max(0, KeepN));
  for s := 0 to MaxSeries - 1 do
    SetLength(KeepV[s], Max(0, KeepN));
  for i := 0 to KeepN - 1 do
  begin
    KeepT[i] := FTimes[First + i];
    for s := 0 to FSeriesCount - 1 do
      KeepV[s][i] := FData[s][First + i];
  end;

  Inc(FDataVersion);           // history replaces the data: index is rebuilt
  FTimes := Copy(T, 0, Length(T));
  for s := 0 to MaxSeries - 1 do
    FData[s] := Copy(V[s], 0, Length(V[s]));
  FCount := N;
  for i := 0 to KeepN - 1 do
  begin
    for s := 0 to FSeriesCount - 1 do
      Vals[s] := KeepV[s][i];
    AddSample(KeepT[i], Vals);
  end;

  // "All" received, or asked for older data and the oldest sample did not
  // move: the server has nothing older
  if (FCount > 0) and ((FPanel.LastRequestSeconds = 0) or
     (FHistForOlder and (FTimes[0] >= FFirstBefore - OneSecond))) then
    FNoMoreHistory := True;
  FHistForOlder := False;

  AutoAxes;
  if FChkFollow.Checked then
    SetView(LastTime, True)
  else
    SetView(FViewEnd);
end;

procedure TfrmIPCChart.PanelSample(Sender: TObject; T: TDateTime; const V: array of Double);
begin
  AddSample(T, V);
  FDirty := True;
end;

{ server data replaced / subscription changed: load again }
procedure TfrmIPCChart.PanelReset(Sender: TObject);
begin
  Inc(FDataVersion);
  FCount := 0;
  FNoMoreHistory := False;
  SetLength(FZoomStack, 0);
  FChkFollow.Checked := True;
  RequestHistory(Max(FPanel.HistorySeconds, Ceil(FViewSpan * SecsPerDay * 1.5)));
  FPaintBox.Invalidate;
end;

procedure TfrmIPCChart.PanelHistoryChoice(Sender: TObject);
begin
  RequestHistory(FPanel.HistorySeconds);
end;

procedure TfrmIPCChart.AddSample(T: TDateTime; const Vals: array of Double);
var
  s, NewCap: Integer;
begin
  if (FCount > 0) and (T <= FTimes[FCount - 1]) then Exit;   // duplicate / old
  if FCount >= Length(FTimes) then
  begin
    NewCap := Max(4096, Length(FTimes) * 2);
    SetLength(FTimes, NewCap);
    for s := 0 to MaxSeries - 1 do
      SetLength(FData[s], NewCap);
  end;
  FTimes[FCount] := T;
  for s := 0 to FSeriesCount - 1 do
    FData[s][FCount] := Vals[s];
  Inc(FCount);
end;

procedure TfrmIPCChart.RepaintTick(Sender: TObject);
begin
  if FDirty then
  begin
    FDirty := False;
    if FChkFollow.Checked and not FSelecting then
      SetView(LastTime, True)
    else
    begin
      UpdateScrollBar;
      FPaintBox.Invalidate;
    end;
  end;
  // IPCChart.exe /bench: timings once the history is there
  if not FBenchDone and (FCount > 0) and not FPanel.HistoryPending and
     FindCmdLineSwitch('bench', ['/', '-'], True) then
  begin
    FBenchDone := True;
    FRepaint.Enabled := False;
    Application.QueueAsyncCall(@RunBench, 0);
  end;
  // status (connection colour, live rate) once a second
  Inc(FStatusTick);
  if FStatusTick mod 10 = 0 then
    UpdateStatus;
end;

{ ---------- view ---------- }

function TfrmIPCChart.FirstTime: TDateTime;
begin
  if FCount > 0 then Result := FTimes[0] else Result := Now - FViewSpan;
end;

function TfrmIPCChart.LastTime: TDateTime;
begin
  if FCount > 0 then Result := FTimes[FCount - 1] else Result := Now;
end;

function TfrmIPCChart.ViewStart: TDateTime;
begin
  Result := FViewEnd - FViewSpan;
end;

function TfrmIPCChart.LowerBound(T: TDateTime): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  Lo := 0;
  Hi := FCount;
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if FTimes[Mid] < T then Lo := Mid + 1 else Hi := Mid;
  end;
  Result := Lo;
end;

function TfrmIPCChart.NearestIndex(T: TDateTime): Integer;
begin
  Result := -1;
  if FCount = 0 then Exit;
  Result := Min(LowerBound(T), FCount - 1);
  if (Result > 0) and (Abs(FTimes[Result - 1] - T) < Abs(FTimes[Result] - T)) then
    Dec(Result);
end;

procedure TfrmIPCChart.AutoAxes;
var
  s: Integer;
  Lo, Hi, V, Pad: Double;
begin
  Lo := Infinity;
  Hi := -Infinity;
  EnsureIndex;
  for s := 0 to FSeriesCount - 1 do
    if (FSeries[s].Kind <> dkBoolean) and (FCount > 0) and
       FIdx[s].RangeMinMax(@FData[s][0], 0, FCount - 1, V, Pad) then
    begin
      if V < Lo then Lo := V;
      if Pad > Hi then Hi := Pad;
    end;
  if Lo > Hi then
  begin
    Lo := 0;
    Hi := 100;
  end;
  Lo := Min(Lo, 0);
  Pad := Max(1, (Hi - Lo) * 0.05);
  for s := 0 to FSeriesCount - 1 do
  begin
    if FSeries[s].AxisUser then Continue;
    if FSeries[s].Kind = dkBoolean then
    begin
      FSeries[s].AxisMin := -0.25;
      FSeries[s].AxisMax := 1.25;
    end
    else
    begin
      FSeries[s].AxisMin := Lo;
      FSeries[s].AxisMax := Hi + Pad;
    end;
  end;
end;

{ Older data needed for the view? -> ask the server once }
procedure TfrmIPCChart.NeedHistoryFrom(T: TDateTime);
begin
  if FPanel.HistoryPending or FNoMoreHistory or (FCount = 0) then Exit;
  if T >= FirstTime then Exit;
  RequestHistory(Ceil((LastTime - T) * SecsPerDay) + 60, True);
end;

procedure TfrmIPCChart.SetView(AEnd: TDateTime; KeepFollow: Boolean);
var
  TS, TE: TDateTime;
begin
  NeedHistoryFrom(AEnd - FViewSpan * 1.5);
  TS := FirstTime;
  TE := LastTime;
  if AEnd > TE then AEnd := TE;
  if AEnd - FViewSpan < TS then AEnd := Min(TE, TS + FViewSpan);
  FViewEnd := AEnd;
  if not KeepFollow then
  begin
    FChkFollow.OnChange := nil;
    FChkFollow.Checked := FViewEnd >= TE - 2 * OneSecond;
    FMnuFollow.Checked := FChkFollow.Checked;
    FChkFollow.OnChange := @ChkFollowChange;
  end;
  UpdateScrollBar;
  UpdateStatus;
  FPaintBox.Invalidate;
end;

procedure TfrmIPCChart.SetSpan(ASpan: TDateTime; AnchorX: Integer);
var
  R: TRect;
  Frac, Anchor: Double;
begin
  ASpan := EnsureRange(ASpan, MinSpanSeconds * OneSecond, 31.0);
  R := PlotRect;
  if FChkFollow.Checked then
  begin
    FViewSpan := ASpan;
    SetView(LastTime, True);
  end
  else if (AnchorX < 0) or (R.Width <= 0) then
  begin
    Anchor := FViewEnd - FViewSpan / 2;
    FViewSpan := ASpan;
    SetView(Anchor + ASpan / 2);
  end
  else
  begin
    Frac := EnsureRange((AnchorX - R.Left) / R.Width, 0, 1);
    Anchor := ViewStart + Frac * FViewSpan;
    FViewSpan := ASpan;
    SetView(Anchor + (1 - Frac) * ASpan);
  end;
  SyncWindowCombo;
end;

procedure TfrmIPCChart.SyncWindowCombo;
var
  i, Idx: Integer;
begin
  Idx := -1;
  for i := Low(WindowSeconds) to High(WindowSeconds) do
    if Abs(FViewSpan * SecsPerDay - WindowSeconds[i]) < 0.5 then Idx := i;
  if FCmbWindow.ItemIndex <> Idx then FCmbWindow.ItemIndex := Idx;
end;

procedure TfrmIPCChart.UpdateScrollBar;
var
  TotalSec, PageSec, PosSec: Integer;
begin
  FUpdatingScroll := True;
  try
    TotalSec := Max(1, Round((LastTime - FirstTime) * SecsPerDay));
    PageSec := EnsureRange(Round(FViewSpan * SecsPerDay), 1, TotalSec);
    PosSec := EnsureRange(Round((ViewStart - FirstTime) * SecsPerDay), 0, TotalSec);
    FScrollBar.SetParams(PosSec, 0, TotalSec, PageSec);
    FScrollBar.LargeChange := EnsureRange(PageSec div 2, 1, 32767);   // TScrollBarInc = 1..32767
    FScrollBar.SmallChange := EnsureRange(PageSec div 20, 1, 32767);
  finally
    FUpdatingScroll := False;
  end;
end;

procedure TfrmIPCChart.UpdateStatus;
var
  S: string;
begin
  if FPanel.Connected then FShpState.Brush.Color := clLime
  else FShpState.Brush.Color := clRed;
  if FCount > 0 then
    S := Format('%d samples  %s - %s', [FCount, FormatDateTime('dd/mm hh:nn:ss', FirstTime),
      FormatDateTime('dd/mm hh:nn:ss', LastTime)])
  else
    S := 'no data';
  S := S + Format('  |  live %.1f/s', [FPanel.LiveRate]);
  if FPanel.HistoryPending then
    S := S + '  |  requesting history ...'
  else if FNoMoreHistory then
    S := S + '  |  all server history loaded';
  if Length(FZoomStack) > 0 then
    S := S + Format('  |  zoom level %d (Ctrl+Z = undo)', [Length(FZoomStack)]);
  FLblStatus.Caption := S;
  FBtnMore.Enabled := not FPanel.HistoryPending and not FNoMoreHistory and FPanel.Connected;
  UpdateDataGrid;
end;

{ ---------- zoom box ---------- }

procedure TfrmIPCChart.PushZoom;
var
  Z: TZoomState;
  s: Integer;
begin
  Z.ViewEnd := FViewEnd;
  Z.ViewSpan := FViewSpan;
  Z.Follow := FChkFollow.Checked;
  for s := 0 to MaxSeries - 1 do
    Z.Series[s] := FSeries[s];
  SetLength(FZoomStack, Length(FZoomStack) + 1);
  FZoomStack[High(FZoomStack)] := Z;
end;

procedure TfrmIPCChart.UndoZoom;
var
  Z: TZoomState;
  s: Integer;
begin
  if Length(FZoomStack) = 0 then
  begin
    MnuResetZoomClick(nil);
    Exit;
  end;
  Z := FZoomStack[High(FZoomStack)];
  SetLength(FZoomStack, Length(FZoomStack) - 1);
  for s := 0 to FSeriesCount - 1 do
  begin
    FSeries[s].AxisMin := Z.Series[s].AxisMin;
    FSeries[s].AxisMax := Z.Series[s].AxisMax;
    FSeries[s].AxisUser := Z.Series[s].AxisUser;
  end;
  FViewSpan := Z.ViewSpan;
  if Z.Follow then
  begin
    FChkFollow.Checked := True;
    SetView(LastTime, True);
  end
  else
    SetView(Z.ViewEnd);
  SyncWindowCombo;
end;

{ the selected time range and value range fill the plot }
procedure TfrmIPCChart.ZoomToRect(const Sel: TRect);
var
  R: TRect;
  s: Integer;
  T1, T2, VTop, VBottom, Span: Double;
  DoX, DoY: Boolean;
begin
  R := PlotRect;
  DoX := Sel.Width >= 6;
  DoY := Sel.Height >= 6;
  if not (DoX or DoY) or (R.Width <= 0) or (R.Height <= 0) then Exit;
  PushZoom;
  if DoY then
    for s := 0 to FSeriesCount - 1 do
      if FSeries[s].Visible then
      begin
        Span := FSeries[s].AxisMax - FSeries[s].AxisMin;
        VTop := FSeries[s].AxisMin + (R.Bottom - Sel.Top) / R.Height * Span;
        VBottom := FSeries[s].AxisMin + (R.Bottom - Sel.Bottom) / R.Height * Span;
        FSeries[s].AxisMin := VBottom;
        FSeries[s].AxisMax := VTop;
        FSeries[s].AxisUser := True;
      end;
  if DoX then
  begin
    T1 := ViewStart + (Sel.Left - R.Left) / R.Width * FViewSpan;
    T2 := ViewStart + (Sel.Right - R.Left) / R.Width * FViewSpan;
    FViewSpan := Max(T2 - T1, MinSpanSeconds * OneSecond);
    FChkFollow.OnChange := nil;
    FChkFollow.Checked := False;
    FMnuFollow.Checked := False;
    FChkFollow.OnChange := @ChkFollowChange;
    SetView((T1 + T2) / 2 + FViewSpan / 2);
    SyncWindowCombo;
  end
  else
    FPaintBox.Invalidate;
end;

function TfrmIPCChart.VisibleAxisCount: Integer;
var
  s: Integer;
begin
  Result := 0;
  for s := 0 to FSeriesCount - 1 do
    if FSeries[s].Visible then Inc(Result);
end;

function TfrmIPCChart.AxisLeft(S: Integer): Integer;
var
  i, n: Integer;
begin
  if not FSeries[S].Visible then Exit(-1);
  n := 0;
  for i := 0 to S - 1 do
    if FSeries[i].Visible then Inc(n);
  Result := 4 + n * AxisWidth;
end;

function TfrmIPCChart.AxisAt(X, Y: Integer): Integer;
var
  s, L: Integer;
  R: TRect;
begin
  Result := -1;
  R := PlotRect;
  if (Y < R.Top - 22) or (Y > R.Bottom) then Exit;
  for s := 0 to FSeriesCount - 1 do
  begin
    L := AxisLeft(s);
    if (L >= 0) and (X >= L) and (X < L + AxisWidth) then Exit(s);
  end;
end;

function TfrmIPCChart.PlotRect: TRect;
begin
  Result := Rect(8 + Max(1, VisibleAxisCount) * AxisWidth, 52,
    FPaintBox.Width - 16, FPaintBox.Height - XAxisHeight - 4);
end;

function TfrmIPCChart.DisplayValue(S: Integer; V: Double): string;
begin
  if IsNan(V) then Exit('-');
  case FSeries[S].Kind of
    dkBoolean: if V >= 0.5 then Result := 'True' else Result := 'False';
    dkByte, dkInteger: Result := IntToStr(Round(V));
  else
    Result := FormatFloat('0.00', V);
  end;
end;

{ ---------- data grid / grid lines ---------- }

{ rows = samples in the chart view }
procedure TfrmIPCChart.UpdateDataGrid(Columns: Boolean);
var
  Titles: array of string;
  s, Last: Integer;
begin
  if (FDataGrid = nil) or not FDataGrid.Visible then Exit;
  if Columns then
  begin
    SetLength(Titles, 2 + FSeriesCount);
    Titles[0] := '#';
    Titles[1] := 'Time';
    for s := 0 to FSeriesCount - 1 do
      Titles[2 + s] := FSeries[s].Name + ' [' + KindNames[FSeries[s].Kind] + ']';
    FDataGrid.SetColumns(Titles);
  end;
  if FCount = 0 then
  begin
    FGridFirst := 0;
    FDataGrid.UpdateRows(0, 'no data', False);
    Exit;
  end;
  FGridFirst := LowerBound(ViewStart);
  Last := LowerBound(FViewEnd + OneMillisecond) - 1;
  FDataGrid.UpdateRows(Max(0, Last - FGridFirst + 1),
    Format('%d samples in view', [Max(0, Last - FGridFirst + 1)]), FChkFollow.Checked);
end;

function TfrmIPCChart.DataGridCell(Row, Col: Integer): string;
var
  i: Integer;
begin
  Result := '';
  i := FGridFirst + Row;
  if (i < 0) or (i >= FCount) then Exit;
  case Col of
    0: Result := IntToStr(i + 1);
    1: Result := FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FTimes[i]);
  else
    if Col - 2 < FSeriesCount then
      Result := DisplayValue(Col - 2, FData[Col - 2][i]);
  end;
end;

{ double-click a row: show that sample in the middle of the chart }
procedure TfrmIPCChart.DataGridRowDblClick(Sender: TObject; Row: Integer);
var
  i: Integer;
begin
  i := FGridFirst + Row;
  if (i < 0) or (i >= FCount) then Exit;
  FChkFollow.Checked := False;
  SetView(FTimes[i] + FViewSpan / 2);
end;

procedure TfrmIPCChart.MnuDataGridClick(Sender: TObject);
begin
  FMnuDataGrid.Checked := not FMnuDataGrid.Checked;
  FDataGrid.Visible := FMnuDataGrid.Checked;
  FDataGridSplitter.Visible := FMnuDataGrid.Checked;
  if FDataGrid.Visible then
  begin
    // at the very bottom, under the time scrollbar
    FDataGrid.Top := ClientHeight;
    FDataGridSplitter.Top := FDataGrid.Top - 1;
    UpdateDataGrid(True);
  end;
end;

procedure TfrmIPCChart.MnuGridLinesClick(Sender: TObject);
begin
  FShowGrid := not FShowGrid;
  FMnuGridLines.Checked := FShowGrid;
  FPaintBox.Invalidate;
end;

{ ---------- drawing ---------- }

procedure TfrmIPCChart.DrawChart(P: TChartPainter; W, H: Integer);
var
  R: TRect;
  M: TXMap;
  PW, PH, s, i, i0, i1, Step, AxL, AxX, NTicks, Idx, px, CurPx, BCount, Day: Integer;
  TStart, Span, SpanSec, T0Sec, TSec, YStep, V, BMin, BMax, BFirst, BLast: Double;
  X, Yf, LegendX, BX: Single;
  Pts: array of TPointF;
  NPts: Integer;
  Fmt, Txt: string;
  C, Dim: TBGRAPixel;

  function YOf(S: Integer; Value: Double): Single;
  begin
    Result := R.Bottom - (Value - FSeries[S].AxisMin) /
      (FSeries[S].AxisMax - FSeries[S].AxisMin) * PH;
  end;

  function XOf(T: TDateTime): Single;
  begin
    Result := R.Left + (T - TStart) / Span * PW;
  end;

  procedure AddPt(AX, AY: Single);
  begin
    if NPts >= Length(Pts) then SetLength(Pts, NPts * 2 + 256);
    Pts[NPts] := PointF(AX, AY);
    Inc(NPts);
  end;

  procedure FlushSegment(S: Integer);
  begin
    if NPts >= 2 then
      P.Polyline(Copy(Pts, 0, NPts), FSeries[S].Color, 1.5)
    else if NPts = 1 then
      P.Circle(Pts[0].X, Pts[0].Y, 1.5, FSeries[S].Color, BGRAPixelTransparent, 0);
    NPts := 0;
  end;

  procedure EmitBucket(S: Integer);
  var
    PX0: Single;
  begin
    if BCount = 0 then Exit;
    if BCount = 1 then
    begin
      Yf := YOf(S, BFirst);
      if (FSeries[S].Kind = dkBoolean) and (NPts > 0) and (Pts[NPts - 1].Y <> Yf) then
        AddPt(BX, Pts[NPts - 1].Y);
      AddPt(BX, Yf);
    end
    else
    begin
      PX0 := R.Left + CurPx + 0.5;
      AddPt(PX0, YOf(S, BFirst));
      AddPt(PX0, YOf(S, BMin));
      AddPt(PX0, YOf(S, BMax));
      AddPt(PX0, YOf(S, BLast));
    end;
    BCount := 0;
  end;

begin
  R := PlotRect;
  PW := R.Width;
  PH := R.Height;
  P.FillRect(0, 0, W, H, BackColor);
  if (PW < 20) or (PH < 20) then Exit;
  P.FillRect(R.Left, R.Top, R.Right, R.Bottom, BGRA(16, 18, 22));
  NTicks := Max(2, PH div 40);
  TStart := ViewStart;
  Span := FViewSpan;

  if (FSeriesCount = 0) or (FCount = 0) then
  begin
    if FPanel.Connected then Txt := 'Waiting for data ...'
    else Txt := 'Not connected - start HistoryRandomData (IPC server on)';
    P.Text((R.Left + R.Right) / 2, (R.Top + R.Bottom) / 2 - 8, Txt, BGRA(170, 170, 180), taCenter);
    if FSeriesCount = 0 then Exit;
  end;

  // before the oldest received sample
  if (FCount > 0) and (FTimes[0] > TStart) then
  begin
    X := Min(XOf(FTimes[0]), R.Right);
    P.FillRect(R.Left, R.Top, X, R.Bottom, BGRA(255, 255, 255, 10));
    if FPanel.HistoryPending then Txt := 'requesting older data ...'
    else if FNoMoreHistory then Txt := 'no older data on the server'
    else Txt := 'older data: scroll back to request';
    if X - R.Left > P.TextWidth(Txt) + 10 then
      P.Text((R.Left + X) / 2, R.Top + 26, Txt, BGRA(150, 150, 160), taCenter);
  end;

  // Y axes
  for s := 0 to FSeriesCount - 1 do
  begin
    AxL := AxisLeft(s);
    if AxL < 0 then Continue;
    C := FSeries[s].Color;
    Dim := BGRA(C.red, C.green, C.blue, 150);
    AxX := AxL + AxisWidth - 6;
    YStep := NiceStep((FSeries[s].AxisMax - FSeries[s].AxisMin) / NTicks);
    if FSeries[s].Kind in [dkByte, dkInteger] then YStep := Max(1, YStep);
    if FSeries[s].Kind = dkBoolean then YStep := 1;
    if s = FAxisDrag then
      P.FillRect(AxL, R.Top - 22, AxL + AxisWidth - 2, R.Bottom + 1,
        BGRA(C.red, C.green, C.blue, 28));
    P.VLine(AxX, R.Top, R.Bottom, C);
    P.Text(AxL + (AxisWidth - 4) / 2, R.Top - 20, 'Y' + IntToStr(s + 1), C, taCenter);
    V := Ceil(FSeries[s].AxisMin / YStep) * YStep;
    while V <= FSeries[s].AxisMax + YStep * 1e-6 do
    begin
      if not ((FSeries[s].Kind = dkBoolean) and ((V < 0) or (V > 1))) then
      begin
        Yf := YOf(s, V);
        P.HLine(AxX - 4, AxX, Round(Yf), C);
        if FSeries[s].Kind = dkBoolean then Txt := DisplayValue(s, V)
        else Txt := FormatAxisValue(V, YStep);
        P.Text(AxX - 6, Yf - 8, Txt, Dim, taRightJustify);
        if FShowGrid and (s = 0) then
          P.HLine(R.Left, R.Right - 1, Round(Yf), BGRA(C.red, C.green, C.blue, 35));
      end;
      V := V + YStep;
    end;
  end;

  // time grid
  SpanSec := Span * SecsPerDay;
  Step := TimeSteps[High(TimeSteps)];
  for i := Low(TimeSteps) to High(TimeSteps) do
    if TimeSteps[i] >= SpanSec / Max(2, PW div 110) then
    begin
      Step := TimeSteps[i];
      Break;
    end;
  if Step < 60 then Fmt := 'hh:nn:ss'
  else if Step < 7200 then Fmt := 'hh:nn'
  else Fmt := 'dd/mm hh:nn';
  T0Sec := TStart * SecsPerDay;
  TSec := Ceil(T0Sec / Step) * Step;
  while TSec <= T0Sec + SpanSec do
  begin
    X := XOf(TSec / SecsPerDay);
    if FShowGrid then
      P.VLine(Round(X), R.Top, R.Bottom - 1, BGRA(50, 54, 62));
    P.VLine(Round(X), R.Bottom, R.Bottom + 4, BGRA(130, 130, 140));
    P.Text(X, R.Bottom + 6, FormatDateTime(Fmt, TSec / SecsPerDay), BGRA(170, 170, 180), taCenter);
    TSec := TSec + Step;
  end;

  // midnight
  Day := Trunc(TStart) + 1;
  while Day <= FViewEnd do
  begin
    X := XOf(Day);
    P.Line(X, R.Top, X, R.Bottom, BGRA(200, 200, 120, 120), 1, psDash);
    P.Text(X + 4, R.Top + 4, FormatDateTime('ddd dd/mm/yyyy', Day), BGRA(200, 200, 120));
    Inc(Day);
  end;

  // data
  if FCount > 0 then
  begin
    i0 := Max(0, LowerBound(TStart) - 1);
    i1 := Min(FCount - 1, LowerBound(FViewEnd));
    P.Clip(R);
    EnsureIndex;
    M := TimeXMap(@FTimes[0], FCount, TStart, Span, PW);
    for s := 0 to FSeriesCount - 1 do
    begin
      if not FSeries[s].Visible then Continue;
      // dense: column rendering (pyramid), sparse: antialiased polyline
      FDense[s] := i1 - i0 + 1 > PW div 2;
      if FDense[s] then
      begin
        DrawDenseSeries(P, R, M, @FData[s][0], i0, i1, FIdx[s], FGaps, FSeries[s].AxisMin,
          FSeries[s].AxisMax, FSeries[s].Color, 1.5, FSeries[s].Kind = dkBoolean, False,
          FColLo, FColHi);
        Continue;
      end;
      NPts := 0;
      BCount := 0;
      CurPx := MaxInt;
      for i := i0 to i1 do
      begin
        V := FData[s][i];
        if IsNan(V) then
        begin
          EmitBucket(s);
          FlushSegment(s);
          Continue;
        end;
        if (i > i0) and ((FTimes[i] - FTimes[i - 1]) * SecsPerDay > GapSeconds) then
        begin
          EmitBucket(s);
          FlushSegment(s);
        end;
        X := XOf(FTimes[i]);
        px := Floor(X) - R.Left;
        if (BCount = 0) or (px <> CurPx) then
        begin
          EmitBucket(s);
          CurPx := px;
          BX := X;
          BFirst := V;
          BMin := V;
          BMax := V;
          BLast := V;
          BCount := 1;
        end
        else
        begin
          if V < BMin then BMin := V;
          if V > BMax then BMax := V;
          BLast := V;
          Inc(BCount);
        end;
      end;
      EmitBucket(s);
      FlushSegment(s);
    end;
    P.NoClip;
  end;

  // legend
  LegendX := R.Left;
  for s := 0 to FSeriesCount - 1 do
  begin
    if FSeries[s].Visible then C := FSeries[s].Color else C := BGRA(90, 90, 95);
    P.Line(LegendX, 15, LegendX + 22, 15, C, 2);
    Txt := Format('Y%d: %s [%s]', [s + 1, FSeries[s].Name, KindNames[FSeries[s].Kind]]);
    P.Text(LegendX + 28, 7, Txt, BGRA(220, 220, 225));
    LegendX := LegendX + 28 + P.TextWidth(Txt) + 28;
  end;

  P.Frame(R.Left, R.Top, R.Right, R.Bottom, BGRA(90, 95, 105));
end;

procedure TfrmIPCChart.PaintBoxPaint(Sender: TObject);
begin
  if (FPaintBox.Width < 200) or (FPaintBox.Height < 100) then Exit;
  if FFrame = nil then
    FFrame := TBGRABitmap.Create(FPaintBox.Width, FPaintBox.Height, BackColor)
  else if (FFrame.Width <> FPaintBox.Width) or (FFrame.Height <> FPaintBox.Height) then
    FFrame.SetSize(FPaintBox.Width, FPaintBox.Height);
  RenderFrame(FFrame);
  FFrame.Draw(FPaintBox.Canvas, 0, 0, True);
end;

{ ---------- speed engine ---------- }

{ index (pyramid, prefix sums, gaps) up to date: appended samples are
  added, replaced / prepended data is indexed again }
procedure TfrmIPCChart.EnsureIndex;
var
  s: Integer;
begin
  if (FIndexVersion <> FDataVersion) or (FIdx[0].Count > FCount) then
  begin
    for s := 0 to MaxSeries - 1 do
      FIdx[s].Clear;
    FGaps.Build(nil, 0, GapSeconds);
    FIndexVersion := FDataVersion;
  end;
  if FCount = 0 then Exit;
  for s := 0 to FSeriesCount - 1 do
    FIdx[s].Append(@FData[s][0], FCount);
  FGaps.Append(@FTimes[0], FCount);
end;

{ everything the cached chart depends on }
function TfrmIPCChart.ChartSignature(W, H: Integer): string;
var
  i: Integer;
  LastT: Double;
begin
  if FCount > 0 then LastT := FTimes[FCount - 1] else LastT := 0;
  Result := Format('%d|%d|%d|%d|%.12g|%.12g|%.12g|%d|%d|%d|%s',
    [W, H, FCount, FDataVersion, LastT, FViewEnd, FViewSpan, Ord(FShowGrid), FAxisDrag,
     FSeriesCount, IntToStr(Ord(FPanel.HistoryPending)) + IntToStr(Ord(FNoMoreHistory)) + IntToStr(Ord(FPanel.Connected))]);
  for i := 0 to FSeriesCount - 1 do
    with FSeries[i] do
      Result := Result + Format('|%.9g|%.9g|%d|%d|%d',
        [AxisMin, AxisMax, Ord(Visible), LongInt(Color), Ord(Kind)]);
end;

{ cached chart (rendered again only when the signature changes) + overlay }
procedure TfrmIPCChart.RenderFrame(Dest: TBGRABitmap);
var
  P: TBGRAChartPainter;
begin
  if FLayer.NeedsRender(Dest.Width, Dest.Height, ChartSignature(Dest.Width, Dest.Height)) then
  begin
    P := TBGRAChartPainter.Create(FLayer.Bitmap);
    try
      DrawChart(P, Dest.Width, Dest.Height);
    finally
      P.Free;
    end;
  end;
  Dest.PutImage(0, 0, FLayer.Bitmap, dmSet);
  P := TBGRAChartPainter.Create(Dest);
  try
    DrawOverlay(P);
  finally
    P.Free;
  end;
end;

{ mouse layer: crosshair + readout (or the hint) and the zoom box }
procedure TfrmIPCChart.DrawOverlay(P: TChartPainter);
var
  R: TRect;
  PW, PH, s, Idx: Integer;
  TStart, Span, SpanSec, T: Double;
  X, LegendX: Single;
  Txt: string;
  C: TBGRAPixel;

  function YOf(S: Integer; Value: Double): Single;
  begin
    Result := R.Bottom - (Value - FSeries[S].AxisMin) /
      (FSeries[S].AxisMax - FSeries[S].AxisMin) * PH;
  end;

begin
  R := PlotRect;
  PW := R.Width;
  PH := R.Height;
  if (PW < 20) or (PH < 20) then Exit;
  TStart := ViewStart;
  Span := FViewSpan;
  SpanSec := Span * SecsPerDay;
  if (FCount > 0) and (FSeriesCount > 0) then
  begin
    if (FHoverX >= R.Left) and (FHoverX < R.Right) and (FHoverY >= R.Top) and
       (FHoverY <= R.Bottom) and not FDragging and not FSelecting and (FAxisDrag < 0) then
    begin
      T := TStart + (FHoverX - R.Left) / PW * Span;
      Idx := NearestIndex(T);
      if (Idx >= 0) and (Abs(FTimes[Idx] - T) * SecsPerDay <= Max(GapSeconds, SpanSec / PW * 2)) then
      begin
        X := R.Left + (FTimes[Idx] - TStart) / Span * PW;
        P.Line(X, R.Top, X, R.Bottom, BGRA(255, 255, 255, 110), 1);
        LegendX := R.Right - 4;
        for s := FSeriesCount - 1 downto 0 do
          if FSeries[s].Visible then
          begin
            if not IsNan(FData[s][Idx]) then
              P.Circle(X, YOf(s, FData[s][Idx]), 3.5, FSeries[s].Color, BGRAPixelTransparent, 0);
            Txt := DisplayValue(s, FData[s][Idx]);
            P.Text(LegendX, 28, Txt, FSeries[s].Color, taRightJustify);
            LegendX := LegendX - P.TextWidth(Txt) - 16;
          end;
        P.Text(LegendX, 28, FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FTimes[Idx]),
          BGRA(240, 240, 240), taRightJustify);
      end;
    end
    else
      P.Text(R.Left, 28, 'Drag box = zoom (right-to-left = undo), wheel = zoom time, ' +
        'right-drag / drag X axis = scroll, drag Y axis = move, double-click Y axis = auto',
        BGRA(120, 124, 132));
  end;

  if FSelecting and ((Abs(FSelEnd.X - FSelStart.X) > 2) or (Abs(FSelEnd.Y - FSelStart.Y) > 2)) then
  begin
    if FSelEnd.X < FSelStart.X - 5 then C := BGRA(255, 120, 120)   // backwards = undo
    else C := BGRA(120, 180, 255);
    P.FillRect(Min(FSelStart.X, FSelEnd.X), Min(FSelStart.Y, FSelEnd.Y),
      Max(FSelStart.X, FSelEnd.X), Max(FSelStart.Y, FSelEnd.Y), BGRA(C.red, C.green, C.blue, 40));
    P.Frame(Min(FSelStart.X, FSelEnd.X), Min(FSelStart.Y, FSelEnd.Y),
      Max(FSelStart.X, FSelEnd.X), Max(FSelStart.Y, FSelEnd.Y), C, 1.01);
    if FSelEnd.X < FSelStart.X - 5 then
      P.Text(Min(FSelStart.X, FSelEnd.X) + 4, Min(FSelStart.Y, FSelEnd.Y) + 2, 'Undo zoom', C);
  end;
end;

{ /bench: off-screen timings of the data on hand (bench.txt next to the exe) }
procedure TfrmIPCChart.RunBench(Data: PtrInt);
var
  SL: TStringList;
  Bmp: TBGRABitmap;

  function Ms(A, B, F: Int64): Double;
  begin
    Result := (B - A) * 1000 / F;
  end;

  procedure Measure(const ACaption: string);
  var
    R: TRect;
    k, Vis: Integer;
    T0, T1, F: Int64;
    Full, Hover: Double;
  begin
    R := PlotRect;
    Vis := LowerBound(FViewEnd + OneMillisecond) - LowerBound(ViewStart);
    FHoverX := -1;
    RenderFrame(Bmp);
    QueryPerformanceFrequency(F);
    QueryPerformanceCounter(T0);
    for k := 1 to 20 do
    begin
      FLayer.Invalidate;                 // force a full render
      RenderFrame(Bmp);
    end;
    QueryPerformanceCounter(T1);
    Full := Ms(T0, T1, F) / 20;
    FHoverY := (R.Top + R.Bottom) div 2;
    QueryPerformanceCounter(T0);
    for k := 1 to 100 do
    begin
      FHoverX := R.Left + (k * 17) mod Max(1, R.Width);
      RenderFrame(Bmp);
    end;
    QueryPerformanceCounter(T1);
    Hover := Ms(T0, T1, F) / 100;
    FHoverX := -1;
    SL.Add(Format('%-22s visible %8d   full redraw %8.2f ms   hover %8.2f ms',
      [ACaption, Vis, Full, Hover]));
  end;

begin
  SL := TStringList.Create;
  Bmp := TBGRABitmap.Create(1200, 600, BackColor);
  try
    FPaintBox.Align := alNone;
    FPaintBox.SetBounds(0, 0, 1200, 600);
    SL.Add(Format('TfrmIPCChart bench  %s  samples %d  chart 1200 x 600',
      [{$ifopt R+}'DEBUG (range checks)'{$else}'RELEASE'{$endif}, FCount]));
    FViewSpan := Max(LastTime - FirstTime, 60 * OneSecond);
    SetView(LastTime);
    Measure('all data');
    FViewSpan := 600 * OneSecond;
    SetView(LastTime);
    Measure('10 min window');
    SL.SaveToFile(ExtractFilePath(ParamStr(0)) + 'bench.txt');
  finally
    Bmp.Free;
    SL.Free;
  end;
  Application.Terminate;
end;

{ ---------- mouse ---------- }

procedure TfrmIPCChart.PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  A: Integer;
  R: TRect;
begin
  if FDragging or FSelecting or (FAxisDrag >= 0) then Exit;
  R := PlotRect;
  A := AxisAt(X, Y);
  if (Button = mbLeft) and (A >= 0) then
  begin
    // left on a Y axis: move that axis
    FAxisDrag := A;
    FAxisDragY := Y;
    FAxisDragMin := FSeries[A].AxisMin;
  end
  else if (Button = mbLeft) and R.Contains(Point(X, Y)) then
  begin
    // left in the chart: zoom box
    FSelecting := True;
    FSelStart := Point(X, Y);
    FSelEnd := FSelStart;
    FPaintBox.Cursor := crCross;
  end
  else if ((Button = mbLeft) and (Y > R.Bottom)) or
          ((Button = mbRight) and R.Contains(Point(X, Y))) then
  begin
    // left on the time axis or right in the chart: scroll in time
    FDragging := True;
    FDragX := X;
    FDragEnd := FViewEnd;
    FPaintBox.Cursor := crSizeWE;
  end;
  FPaintBox.Invalidate;
end;

procedure TfrmIPCChart.PaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  R: TRect;
  Span: Double;
begin
  FHoverX := X;
  FHoverY := Y;
  R := PlotRect;
  if FSelecting then
  begin
    FSelEnd := Point(EnsureRange(X, R.Left, R.Right), EnsureRange(Y, R.Top, R.Bottom));
    FPaintBox.Invalidate;
  end
  else if FAxisDrag >= 0 then
  begin
    Span := FSeries[FAxisDrag].AxisMax - FSeries[FAxisDrag].AxisMin;
    FSeries[FAxisDrag].AxisMin := FAxisDragMin + (Y - FAxisDragY) / Max(1, R.Height) * Span;
    FSeries[FAxisDrag].AxisMax := FSeries[FAxisDrag].AxisMin + Span;
    FSeries[FAxisDrag].AxisUser := True;
    FPaintBox.Invalidate;
  end
  else if FDragging then
  begin
    if R.Width > 0 then
      SetView(FDragEnd - (X - FDragX) / R.Width * FViewSpan);
  end
  else
  begin
    if AxisAt(X, Y) >= 0 then FPaintBox.Cursor := crSizeNS
    else if R.Contains(Point(X, Y)) then FPaintBox.Cursor := crCross
    else if Y > R.Bottom then FPaintBox.Cursor := crSizeWE
    else FPaintBox.Cursor := crDefault;
    FPaintBox.Invalidate;
  end;
end;

procedure TfrmIPCChart.PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Sel: TRect;
begin
  if FSelecting and (Button = mbLeft) then
  begin
    FSelecting := False;
    Sel := Rect(Min(FSelStart.X, FSelEnd.X), Min(FSelStart.Y, FSelEnd.Y),
      Max(FSelStart.X, FSelEnd.X), Max(FSelStart.Y, FSelEnd.Y));
    // right-to-left = undo, left-to-right = zoom in, a click = nothing
    if FSelEnd.X < FSelStart.X - 5 then
      UndoZoom
    else
      ZoomToRect(Sel);
    UpdateStatus;
  end;
  FDragging := False;
  FAxisDrag := -1;
  FPaintBox.Cursor := crDefault;
  FPaintBox.Invalidate;
end;

{ the right button scrolls the chart - no popup menu }
procedure TfrmIPCChart.PaintBoxContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
begin
  Handled := True;
end;

procedure TfrmIPCChart.PaintBoxMouseLeave(Sender: TObject);
begin
  FHoverX := -1;
  FPaintBox.Invalidate;
end;

procedure TfrmIPCChart.PaintBoxDblClick(Sender: TObject);
var
  A: Integer;
begin
  A := AxisAt(FHoverX, FHoverY);
  if A < 0 then Exit;
  FSeries[A].AxisUser := False;
  AutoAxes;
  FPaintBox.Invalidate;
end;

procedure TfrmIPCChart.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  Pt: TPoint;
  A: Integer;
  R: TRect;
  V, F: Double;
begin
  Pt := FPaintBox.ScreenToClient(Mouse.CursorPos);
  if not FPaintBox.ClientRect.Contains(Pt) then Exit;
  Handled := True;
  if WheelDelta > 0 then F := 0.8 else F := 1 / 0.8;
  A := AxisAt(Pt.X, Pt.Y);
  if A >= 0 then
  begin
    R := PlotRect;
    with FSeries[A] do
    begin
      V := AxisMin + (R.Bottom - Pt.Y) / Max(1, R.Height) * (AxisMax - AxisMin);
      AxisMin := V - (V - AxisMin) * F;
      AxisMax := V + (AxisMax - V) * F;
      AxisUser := True;
    end;
    FPaintBox.Invalidate;
  end
  else if ssShift in Shift then
  begin
    if WheelDelta > 0 then SetView(FViewEnd - FViewSpan / 10)
    else SetView(FViewEnd + FViewSpan / 10);
  end
  else
    SetSpan(FViewSpan * F, Pt.X);
end;

{ ---------- controls ---------- }

procedure TfrmIPCChart.ScrollBarChange(Sender: TObject);
begin
  if FUpdatingScroll then Exit;
  SetView(FirstTime + FScrollBar.Position * OneSecond + FViewSpan);
end;

procedure TfrmIPCChart.BtnMoreClick(Sender: TObject);
begin
  if FCount = 0 then Exit;
  NeedHistoryFrom(FirstTime - FViewSpan);
end;

procedure TfrmIPCChart.CmbWindowChange(Sender: TObject);
begin
  if FCmbWindow.ItemIndex >= 0 then
    SetSpan(WindowSeconds[FCmbWindow.ItemIndex] * OneSecond);
end;

procedure TfrmIPCChart.ChkFollowChange(Sender: TObject);
begin
  FMnuFollow.Checked := FChkFollow.Checked;
  if FChkFollow.Checked then
    SetView(LastTime, True);
end;

procedure TfrmIPCChart.MnuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmIPCChart.MnuFollowClick(Sender: TObject);
begin
  FChkFollow.Checked := not FChkFollow.Checked;
end;

procedure TfrmIPCChart.MnuAutoAxesClick(Sender: TObject);
var
  s: Integer;
begin
  for s := 0 to FSeriesCount - 1 do
    FSeries[s].AxisUser := False;
  AutoAxes;
  FPaintBox.Invalidate;
end;

procedure TfrmIPCChart.MnuSeriesClick(Sender: TObject);
var
  s: Integer;
begin
  s := TMenuItem(Sender).Tag;
  FSeries[s].Visible := not FSeries[s].Visible;
  TMenuItem(Sender).Checked := FSeries[s].Visible;
  FPaintBox.Invalidate;
end;

procedure TfrmIPCChart.MnuPanelClick(Sender: TObject);
begin
  FMnuPanel.Checked := not FMnuPanel.Checked;
  FPanel.Visible := FMnuPanel.Checked;
  FSplitter.Visible := FMnuPanel.Checked;
  if FSplitter.Visible then
    FSplitter.Left := FPanel.Left - FSplitter.Width;
end;

procedure TfrmIPCChart.MnuUndoZoomClick(Sender: TObject);
begin
  UndoZoom;
  UpdateStatus;
end;

{ back to the default view: auto Y axes, 3 hours, follow live }
procedure TfrmIPCChart.MnuResetZoomClick(Sender: TObject);
var
  s: Integer;
begin
  SetLength(FZoomStack, 0);
  for s := 0 to FSeriesCount - 1 do
    FSeries[s].AxisUser := False;
  AutoAxes;
  FViewSpan := WindowSeconds[DefaultWindowIndex] * OneSecond;
  SyncWindowCombo;
  FChkFollow.Checked := True;
  SetView(LastTime, True);
end;

end.
