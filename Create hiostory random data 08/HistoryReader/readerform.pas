unit ReaderForm;

{
  History Reader
  --------------
  Reads the CSV files written by HistoryRandomData:
    - the main data file (e.g. history_data.csv)
    - the daily files (daily\<name>_yyyy-mm-dd.csv)
    - single data set exports ("Save this data set...")
  Header "Time;Name [Type];..." (types Boolean / Byte / Integer / Double),
  timestamps as date-time (yyyy-mm-dd hh:nn:ss.zzz) or as TDateTime number.

  * Several files can be opened together (or dropped on the window):
    the samples are merged and sorted by time, duplicates removed.
  * Info panel: files, summary (samples, time range, timestamp format,
    sample interval, gaps) and statistics per data set (whole data or the
    visible range only).
  * Chart: one Y axis per data set, left drag = zoom box (right-to-left =
    undo), right drag / drag on the time axis = scroll, wheel = zoom time,
    gaps break the lines. Panel > Data grid shows the samples in view.
  * Pin data (Panel > Pin data): click on the chart (no drag) or enter a
    date / time to pin a moment; the table lists the values of every pin,
    double-click a row to go there. Pins are part of the PNG / SVG export.
  * Lines (info panel): per data set visible, colour, opacity, line style,
    thickness, draw mode (line / steps / points), marker and marker size;
    kept when other files are opened, used for the chart, legend and exports.
  * The info panel on the right scrolls (scrollbar / mouse wheel).
  * Chart panel (Panel > Chart panel): all properties of the chart (the
    editable ones in blue: view range, span, grid lines, gap threshold, Y
    axis ranges, visibility), detail, status, data samples and memory use.
  * Export: chart as PNG or SVG, the visible samples as CSV.

  Speed (constant paint time from a few thousand to millions of samples):
  * level-of-detail min/max pyramid (blocks of 16, 256, 4096 ... samples)
  * column rendering: more samples than half the plot width -> one
    non-antialiased vertical span per pixel column (line, steps, points,
    width, opacity), antialiased polylines only when zoomed in
  * layer cache: the chart is rendered once into a bitmap; mouse moves
    only copy it and draw the crosshair / readout / zoom box on top
  * prefix sums: count / mean / std dev of any range in O(1), used by the
    statistics, auto Y axes and the chart panel
  * reused frame bitmap, gap index list
  * HistoryReader.exe /bench files... writes timings to bench.txt
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DateUtils, StrUtils, Forms, Controls, Graphics,
  ExtCtrls, StdCtrls, Menus, Dialogs, Grids, Spin, LCLType, BGRABitmap, BGRABitmapTypes,
  ChartPainter, DataGridPanel, Clipbrd;

const
  MaxSeries = 8;
  AxisWidth = 58;
  XAxisHeight = 26;
  MinSpanSeconds = 1;

type
  TDataKind = (dkBoolean, dkByte, dkInteger, dkDouble);
  TDoubleArray = array of Double;
  TTimeArray = array of TDateTime;
  TValueArrays = array[0..MaxSeries - 1] of TDoubleArray;

  TSeriesInfo = record
    Name: string;
    Kind: TDataKind;
    Color: TBGRAPixel;
    Visible: Boolean;
    AxisMin, AxisMax: Double;
    AxisUser: Boolean;
  end;

  TLineMode = (lmLine, lmSteps, lmPoints);
  TMarkerKind = (mkNone, mkCircle, mkSquare, mkCross, mkPlus);

  { look of one data set }
  TLineCfg = record
    Visible: Boolean;
    Color: TBGRAPixel;
    Opacity: Integer;          // 10..100 %
    Style: TPenStyle;
    Width: Single;
    Mode: TLineMode;
    Marker: TMarkerKind;
    MarkerSize: Single;
  end;

  TFileInfo = record
    FileName: string;
    Rows: Integer;
    First, Last: TDateTime;
    TimeFormat: string;
  end;

  TZoomState = record
    ViewEnd, ViewSpan: TDateTime;
    Series: array[0..MaxSeries - 1] of TSeriesInfo;
  end;

  { TfrmReader }

  TfrmReader = class(TForm)
    procedure FormCreate(Sender: TObject);
  public
    destructor Destroy; override;
  private
    // UI
    FMainMenu: TMainMenu;
    FMnuSeries, FMnuInfo, FMnuDataGrid, FMnuGridLines, FMnuPins, FMnuChart: TMenuItem;
    // chart panel
    FChartPanel: TPanel;
    FChartSplitter: TSplitter;
    FPropGrid: TStringGrid;
    FPropKeys: TStringList;        // key of every row ('' = read only, '#' = section)
    FPropTimer: TTimer;
    FPaintCount: Int64;
    FLastPaintMs, FTotalPaintMs: Double;
    FDrawn: array[0..MaxSeries - 1] of Integer;   // points drawn in the last paint
    FLastTimeStep: Integer;
    FFrame: TBGRABitmap;           // reused paint buffer
    // speed: layer cache
    FCache: TBGRABitmap;           // rendered chart without the mouse overlay
    FCacheSig: string;
    FCacheHits, FCacheMisses: Int64;
    FDataVersion: Integer;
    // speed: level of detail + prefix sums + gaps
    FLodSize: array of Integer;                               // 16, 256, 4096 ...
    FLodMin, FLodMax: array[0..MaxSeries - 1] of array of TDoubleArray;
    FPreSum, FPreSum2: array[0..MaxSeries - 1] of TDoubleArray;
    FPreCnt: array[0..MaxSeries - 1] of array of Integer;
    FGapIdx: array of Integer;     // i: gap between sample i-1 and i
    FDense: array[0..MaxSeries - 1] of Boolean;               // last render mode
    // pin data
    FPinPanel: TPanel;
    FPinSplitter: TSplitter;
    FPinGrid: TStringGrid;
    FPinSpins: array[0..5] of TSpinEdit;
    FPins: array of TDateTime;     // pinned sample times, ascending
    // look of every data set (index), kept across file loads
    FLine: array[0..MaxSeries - 1] of TLineCfg;
    FLinesBox, FStatsBox: TGroupBox;
    FLineControls: TList;          // controls of the Lines rows (rebuilt per header)
    FLineVisChk: array[0..MaxSeries - 1] of TCheckBox;
    FUpdatingLines: Boolean;
    FOpenDialog: TOpenDialog;
    FPngDialog, FSvgDialog, FCsvDialog: TSaveDialog;
    FTopPanel: TPanel;
    FCmbWindow: TComboBox;
    FLblStatus: TLabel;
    FInfoPanel: TScrollBox;
    FInfoSplitter, FGridSplitter: TSplitter;
    FFilesGrid, FSummaryGrid, FStatsGrid: TStringGrid;
    FChkStatsView: TCheckBox;
    FDataGrid: TDataGridPanel;
    FPaintBox: TPaintBox;
    FScrollBar: TScrollBar;

    // data
    FFiles: array of TFileInfo;
    FSeriesCount: Integer;
    FSeries: array[0..MaxSeries - 1] of TSeriesInfo;
    FTimes: TTimeArray;
    FData: TValueArrays;
    FCount: Integer;
    FIntervalMs: Double;
    FGapCount: Integer;
    FLongestGap: Double;       // seconds
    FGapSeconds: Double;       // samples further apart are not joined

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
    FShowGrid: Boolean;
    FGridFirst: Integer;

    procedure BuildUI;
    procedure BuildInfoPanel;
    procedure BuildPinPanel;
    procedure BuildLineRows;
    procedure InitLine(S: Integer);
    function LineColor(S: Integer): TBGRAPixel;
    procedure LineVisibleChange(Sender: TObject);
    procedure LineColorChange(Sender: TObject);
    procedure LineOpacityChange(Sender: TObject);
    procedure LineStyleChange(Sender: TObject);
    procedure LineWidthChange(Sender: TObject);
    procedure LineModeChange(Sender: TObject);
    procedure LineMarkerChange(Sender: TObject);
    procedure LineMarkerSizeChange(Sender: TObject);
    procedure BtnResetLinesClick(Sender: TObject);
    procedure AsyncBuildLines(Data: PtrInt);
    procedure InfoGridWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint; var Handled: Boolean);
    function PinIndex(P: Integer): Integer;
    function SelectedPin: Integer;
    procedure AddPin(T: TDateTime; FromChart: Boolean);
    procedure RemovePin(P: Integer);
    procedure RefreshPinGrid;
    procedure GoToPin(P: Integer);
    procedure BtnAddPinClick(Sender: TObject);
    procedure BtnGoToPinClick(Sender: TObject);
    procedure BtnRemovePinClick(Sender: TObject);
    procedure BtnClearPinsClick(Sender: TObject);
    procedure PinGridDblClick(Sender: TObject);
    procedure PinGridKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PinGridSelection(Sender: TObject; aCol, aRow: Integer);
    procedure MnuPinsClick(Sender: TObject);
    procedure MnuChartClick(Sender: TObject);
    procedure BuildChartPanel;
    procedure RefreshChartPanel;
    procedure PropTimerTick(Sender: TObject);
    procedure PropSelectCell(Sender: TObject; aCol, aRow: Integer; var CanSelect: Boolean);
    procedure PropValidate(Sender: TObject; aCol, aRow: Integer; const OldValue: string;
      var NewValue: string);
    procedure PropPrepareCanvas(Sender: TObject; aCol, aRow: Integer; aState: TGridDrawState);
    procedure BtnCopyPropsClick(Sender: TObject);
    procedure PropGridWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint; var Handled: Boolean);
    procedure SetSeriesVisible(S: Integer; AVisible: Boolean);
    // rendering + benchmark
    procedure RenderFrame(Dest: TBGRABitmap);
    procedure DrawOverlay(P: TChartPainter);
    function ChartSignature(W, H: Integer): string;
    // speed structures
    procedure BuildLOD;
    procedure BuildGaps;
    function RangeMinMax(S, A, B: Integer; out Mn, Mx: Double): Boolean;
    procedure RangeSums(S, A, B: Integer; out Sum, Sum2: Double; out Cnt: Integer);
    function GapIndexFrom(I: Integer): Integer;
    function GapsBetween(A, B: Integer): Integer;
    function LodBytes: Int64;
    procedure RunBench(Data: PtrInt);
    procedure BuildSeriesMenu;

    // files
    function ParseFile(const AFileName: string; out T: TTimeArray; out V: TValueArrays;
      out N: Integer; out Header, TimeFmt: string): Boolean;
    procedure SetupSeries(const Header: string; ColCount: Integer);
    procedure LoadFiles(Names: TStrings; Append: Boolean);
    procedure SortAndDedupe;
    procedure Analyse;

    // view
    function FirstTime: TDateTime;
    function LastTime: TDateTime;
    function ViewStart: TDateTime;
    function LowerBound(T: TDateTime): Integer;
    function NearestIndex(T: TDateTime): Integer;
    procedure AutoAxes;
    procedure ShowAll;
    procedure SetView(AEnd: TDateTime);
    procedure SetSpan(ASpan: TDateTime; AnchorX: Integer = -1);
    procedure UpdateScrollBar;
    procedure UpdateStatus;
    procedure UpdateInfo;
    procedure UpdateStats;
    procedure UpdateDataGrid(Columns: Boolean = False);
    procedure SyncWindowCombo;
    procedure PushZoom;
    procedure UndoZoom;
    procedure ZoomToRect(const Sel: TRect);
    function VisibleAxisCount: Integer;
    function AxisLeft(S: Integer): Integer;
    function AxisAt(X, Y: Integer): Integer;
    function PlotRect: TRect;
    function DisplayValue(S: Integer; V: Double): string;
    procedure DrawChart(P: TChartPainter; W, H: Integer; Interactive: Boolean);
    function DataGridCell(Row, Col: Integer): string;
    procedure DataGridRowDblClick(Sender: TObject; Row: Integer);
    procedure DataGridOptionsChange(Sender: TObject);
    procedure UpdateGridColors;

    // events
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
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
    procedure CmbWindowChange(Sender: TObject);
    procedure ChkStatsViewChange(Sender: TObject);
    procedure MnuOpenClick(Sender: TObject);
    procedure MnuAddClick(Sender: TObject);
    procedure MnuReloadClick(Sender: TObject);
    procedure MnuExportPngClick(Sender: TObject);
    procedure MnuExportSvgClick(Sender: TObject);
    procedure MnuExportCsvClick(Sender: TObject);
    procedure MnuExitClick(Sender: TObject);
    procedure MnuUndoZoomClick(Sender: TObject);
    procedure MnuShowAllClick(Sender: TObject);
    procedure MnuAutoAxesClick(Sender: TObject);
    procedure MnuSeriesClick(Sender: TObject);
    procedure MnuInfoClick(Sender: TObject);
    procedure MnuDataGridClick(Sender: TObject);
    procedure MnuGridLinesClick(Sender: TObject);
  end;

var
  frmReader: TfrmReader;

implementation

{$R *.lfm}

const
  WindowSeconds: array[0..9] of Integer = (60, 600, 3600, 10800, 21600, 43200,
    86400, 259200, 604800, 0);
  WindowNames: array[0..9] of string = ('1 min', '10 min', '1 hour', '3 hours',
    '6 hours', '12 hours', '1 day', '3 days', '7 days', 'All');
  TimeSteps: array[0..17] of Integer = (1, 5, 10, 15, 30, 60, 120, 300, 600, 900,
    1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800);
  KindNames: array[TDataKind] of string = ('Boolean', 'Byte', 'Integer', 'Double');
  BackColor: TBGRAPixel = (blue: 32; green: 26; red: 24; alpha: 255);
  CsvFilter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*';
  LineStyles: array[0..4] of TPenStyle = (psSolid, psDash, psDot, psDashDot, psDashDotDot);
  LineStyleNames: array[0..4] of string = ('Solid', 'Dash', 'Dot', 'Dash dot', 'Dash dot dot');
  LineModeNames: array[TLineMode] of string = ('Line', 'Steps', 'Points');
  MarkerNames: array[TMarkerKind] of string = ('None', 'Circle', 'Square', 'Cross', 'Plus');
  LineGroupHeight = 122;

var
  FS: TFormatSettings;
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

function FormatDuration(Sec: Double): string;
var
  D: Integer;
begin
  if Sec < 60 then Exit(FormatFloat('0.0', Sec) + ' s');
  D := Trunc(Sec / 86400);
  Result := FormatDateTime('hh:nn:ss', Sec / 86400);
  if D > 0 then Result := IntToStr(D) + 'd ' + Result;
end;

function FormatBytes(B: Int64): string;
begin
  if B >= 1048576 then Result := Format('%.1f MB', [B / 1048576])
  else if B >= 1024 then Result := Format('%.1f kB', [B / 1024])
  else Result := IntToStr(B) + ' B';
end;

{ "yyyy-mm-dd hh:nn:ss.zzz" (fixed positions) or a TDateTime number }
function ParseTimeStr(const S: string; out T: TDateTime; out IsDouble: Boolean): Boolean;
var
  Y, Mo, D, H, Mi, Se, MS: Integer;
  Dbl: Double;
begin
  IsDouble := False;
  if (Length(S) >= 19) and (S[5] = '-') then
  begin
    Y := StrToIntDef(Copy(S, 1, 4), -1);
    Mo := StrToIntDef(Copy(S, 6, 2), -1);
    D := StrToIntDef(Copy(S, 9, 2), -1);
    H := StrToIntDef(Copy(S, 12, 2), -1);
    Mi := StrToIntDef(Copy(S, 15, 2), -1);
    Se := StrToIntDef(Copy(S, 18, 2), -1);
    MS := 0;
    if Length(S) >= 23 then MS := StrToIntDef(Copy(S, 21, 3), 0);
    Result := (Y > 0) and (Mo > 0) and (D > 0) and (H >= 0) and (Mi >= 0) and (Se >= 0) and
      TryEncodeDateTime(Y, Mo, D, H, Mi, Se, MS, T);
  end
  else
  begin
    IsDouble := True;
    Result := TryStrToFloat(Trim(S), Dbl, FS);
    T := Dbl;
  end;
end;

function ParseValueStr(const S: string): Double;
begin
  if S = '' then Result := NaN
  else if SameText(S, 'TRUE') then Result := 1
  else if SameText(S, 'FALSE') then Result := 0
  else if not TryStrToFloat(Trim(S), Result, FS) then Result := NaN;
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

{ TfrmReader }

procedure TfrmReader.FormCreate(Sender: TObject);
var
  L: TStringList;
  i: Integer;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
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
  FShowGrid := True;
  FViewSpan := OneHour;
  FViewEnd := Now;
  FGapSeconds := 3;
  for i := 0 to MaxSeries - 1 do
    InitLine(i);
  FLineControls := TList.Create;
  BuildUI;

  // HistoryReader.exe file1.csv file2.csv ...
  if ParamCount > 0 then
  begin
    L := TStringList.Create;
    try
      for i := 1 to ParamCount do
        if FileExists(ParamStr(i)) then L.Add(ParamStr(i));
      if L.Count > 0 then LoadFiles(L, False);
    finally
      L.Free;
    end;
  end;
  UpdateInfo;
  UpdateStatus;
  // HistoryReader.exe /bench files...  -> timings to bench.txt, then exit
  if FindCmdLineSwitch('bench', ['/', '-'], True) then
    Application.QueueAsyncCall(@RunBench, 0);
end;

destructor TfrmReader.Destroy;
begin
  FreeAndNil(FLineControls);   // the controls themselves belong to the form
  FreeAndNil(FPropKeys);
  FreeAndNil(FFrame);
  FreeAndNil(FCache);
  inherited Destroy;
end;

procedure TfrmReader.BuildUI;
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

  function NewDialog(const ATitle, AFilter, AExt: string): TSaveDialog;
  begin
    Result := TSaveDialog.Create(Self);
    Result.Title := ATitle;
    Result.Filter := AFilter;
    Result.DefaultExt := AExt;
    Result.Options := Result.Options + [ofOverwritePrompt];
  end;

begin
  DoubleBuffered := True;
  OnMouseWheel := @FormMouseWheel;
  AllowDropFiles := True;
  OnDropFiles := @FormDropFiles;

  // menu
  FMainMenu := TMainMenu.Create(Self);
  Menu := FMainMenu;
  MFile := TMenuItem.Create(FMainMenu);
  MFile.Caption := '&File';
  FMainMenu.Items.Add(MFile);
  AddItem(MFile, '&Open...', @MnuOpenClick, ShortCut(Ord('O'), [ssCtrl]));
  AddItem(MFile, '&Add files...', @MnuAddClick, ShortCut(Ord('O'), [ssCtrl, ssShift]));
  AddItem(MFile, '&Reload', @MnuReloadClick, ShortCut(VK_F5, []));
  AddItem(MFile, '-', nil);
  AddItem(MFile, 'Export chart as &PNG...', @MnuExportPngClick, ShortCut(Ord('E'), [ssCtrl]));
  AddItem(MFile, 'Export chart as S&VG...', @MnuExportSvgClick, ShortCut(Ord('E'), [ssCtrl, ssShift]));
  AddItem(MFile, 'Export visible samples as &CSV...', @MnuExportCsvClick,
    ShortCut(Ord('S'), [ssCtrl, ssShift]));
  AddItem(MFile, '-', nil);
  AddItem(MFile, 'E&xit', @MnuExitClick, ShortCut(Ord('Q'), [ssCtrl]));

  MView := TMenuItem.Create(FMainMenu);
  MView.Caption := '&View';
  FMainMenu.Items.Add(MView);
  AddItem(MView, 'Show &all', @MnuShowAllClick, ShortCut(Ord('0'), [ssCtrl]));
  AddItem(MView, '&Undo zoom', @MnuUndoZoomClick, ShortCut(Ord('Z'), [ssCtrl]));
  AddItem(MView, 'Auto &Y axes', @MnuAutoAxesClick, ShortCut(Ord('R'), [ssCtrl]));
  AddItem(MView, '-', nil);
  FMnuSeries := AddItem(MView, '&Data sets', nil);

  MPanel := TMenuItem.Create(FMainMenu);
  MPanel.Caption := '&Panel';
  FMainMenu.Items.Add(MPanel);
  FMnuInfo := AddItem(MPanel, '&Info panel', @MnuInfoClick, ShortCut(Ord('I'), [ssCtrl]));
  FMnuInfo.Checked := True;
  FMnuDataGrid := AddItem(MPanel, '&Data grid', @MnuDataGridClick, ShortCut(Ord('T'), [ssCtrl]));
  FMnuGridLines := AddItem(MPanel, 'Grid &lines', @MnuGridLinesClick);
  FMnuGridLines.Checked := True;
  FMnuPins := AddItem(MPanel, '&Pin data', @MnuPinsClick, ShortCut(Ord('P'), [ssCtrl]));
  FMnuPins.Checked := True;
  FMnuChart := AddItem(MPanel, '&Chart panel', @MnuChartClick, ShortCut(Ord('K'), [ssCtrl]));

  FOpenDialog := TOpenDialog.Create(Self);
  FOpenDialog.Title := 'Open CSV files from HistoryRandomData';
  FOpenDialog.Filter := CsvFilter;
  FOpenDialog.Options := FOpenDialog.Options + [ofAllowMultiSelect, ofFileMustExist];
  FPngDialog := NewDialog('Export chart as PNG', 'PNG image (*.png)|*.png', 'png');
  FSvgDialog := NewDialog('Export chart as SVG', 'SVG vector image (*.svg)|*.svg', 'svg');
  FCsvDialog := NewDialog('Export visible samples as CSV', CsvFilter, 'csv');

  // toolbar
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
  FCmbWindow.SetBounds(62, 6, 84, 24);
  FCmbWindow.Style := csDropDownList;
  for i := Low(WindowNames) to High(WindowNames) do
    FCmbWindow.Items.Add(WindowNames[i]);
  FCmbWindow.ItemIndex := High(WindowNames);
  FCmbWindow.OnChange := @CmbWindowChange;

  FLblStatus := TLabel.Create(Self);
  FLblStatus.Parent := FTopPanel;
  FLblStatus.SetBounds(160, 10, 1000, 20);

  BuildInfoPanel;
  FInfoSplitter := TSplitter.Create(Self);
  FInfoSplitter.Parent := Self;
  FInfoSplitter.Align := alRight;
  FInfoSplitter.Left := FInfoPanel.Left - 5;

  BuildPinPanel;
  FPinSplitter := TSplitter.Create(Self);
  FPinSplitter.Parent := Self;
  FPinSplitter.Align := alBottom;
  FPinSplitter.Top := FPinPanel.Top - 5;

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
  FDataGrid.OnOptionsChange := @DataGridOptionsChange;
  FDataGrid.EnableOptions;      // full options bar (columns, formats, look)
  FGridSplitter := TSplitter.Create(Self);
  FGridSplitter.Parent := Self;
  FGridSplitter.Align := alBottom;
  FGridSplitter.Visible := False;

  BuildChartPanel;

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
end;

procedure TfrmReader.BuildInfoPanel;
var
  GB: TGroupBox;

  function NewGrid(AParent: TWinControl; const Titles: array of string;
    const Widths: array of Integer): TStringGrid;
  var
    i: Integer;
  begin
    Result := TStringGrid.Create(Self);
    Result.Parent := AParent;
    Result.Align := alClient;
    Result.FixedCols := 0;
    Result.RowCount := 1;
    Result.ColCount := Length(Titles);
    Result.DefaultRowHeight := 21;
    Result.Options := Result.Options + [goColSizing, goRowSelect] - [goRangeSelect];
    for i := 0 to High(Titles) do
    begin
      Result.Cells[i, 0] := Titles[i];
      Result.ColWidths[i] := Widths[i];
    end;
    // the wheel scrolls the whole panel, not the grid
    Result.OnMouseWheel := @InfoGridWheel;
  end;

begin
  // scrolls vertically: every group keeps its full height
  FInfoPanel := TScrollBox.Create(Self);
  FInfoPanel.Parent := Self;
  FInfoPanel.Align := alRight;
  FInfoPanel.Width := 450;
  FInfoPanel.BorderStyle := bsNone;
  FInfoPanel.HorzScrollBar.Visible := False;
  FInfoPanel.VertScrollBar.Tracking := True;
  FInfoPanel.VertScrollBar.Increment := 30;

  GB := TGroupBox.Create(Self);
  GB.Parent := FInfoPanel;
  GB.Align := alTop;
  GB.Top := 0;
  GB.Height := 140;
  GB.Caption := ' Files (drop CSV files on the window to add) ';
  FFilesGrid := NewGrid(GB, ['File', 'Rows', 'From', 'To', 'Time'], [130, 60, 92, 92, 52]);

  GB := TGroupBox.Create(Self);
  GB.Parent := FInfoPanel;
  GB.Align := alTop;
  GB.Top := 1000;
  GB.Height := 250;
  GB.Caption := ' Summary ';
  FSummaryGrid := NewGrid(GB, ['Property', 'Value'], [130, 280]);

  FLinesBox := TGroupBox.Create(Self);
  FLinesBox.Parent := FInfoPanel;
  FLinesBox.Align := alTop;
  FLinesBox.Top := 2000;
  FLinesBox.Height := 70;
  FLinesBox.Caption := ' Lines - look of every data set ';

  FStatsBox := TGroupBox.Create(Self);
  FStatsBox.Parent := FInfoPanel;
  FStatsBox.Align := alTop;
  FStatsBox.Top := 3000;
  FStatsBox.Height := 170;
  FStatsBox.Caption := ' Statistics ';
  FChkStatsView := TCheckBox.Create(Self);
  FChkStatsView.Parent := FStatsBox;
  FChkStatsView.Align := alTop;
  FChkStatsView.BorderSpacing.Around := 4;
  FChkStatsView.Caption := 'Only the visible range';
  FChkStatsView.OnChange := @ChkStatsViewChange;
  FStatsGrid := NewGrid(FStatsBox, ['Data set', 'Type', 'Count', 'Min', 'Max', 'Mean', 'Std dev'],
    [120, 56, 60, 58, 58, 58, 58]);
end;

procedure TfrmReader.BuildSeriesMenu;
var
  s: Integer;
  Item: TMenuItem;
begin
  RefreshPinGrid;
  BuildLineRows;
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
  UpdateDataGrid(True);
end;

{ ---------- files ---------- }

{ Whole file -> arrays. Header (if any) is returned; without a header the
  number of columns of the first data line is used. }
function TfrmReader.ParseFile(const AFileName: string; out T: TTimeArray;
  out V: TValueArrays; out N: Integer; out Header, TimeFmt: string): Boolean;
var
  F: TFileStream;
  Buf, Line: string;
  P, Q, s, Cap, FieldStart, FieldEnd, Cols: Integer;
  TT: TDateTime;
  IsDbl: Boolean;
begin
  Result := False;
  N := 0;
  Header := '';
  TimeFmt := '?';
  T := nil;
  for s := 0 to MaxSeries - 1 do
    V[s] := nil;
  F := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buf, F.Size);
    if F.Size > 0 then F.ReadBuffer(Buf[1], F.Size);
  finally
    F.Free;
  end;

  Cap := Length(Buf) div 30 + 16;
  SetLength(T, Cap);
  for s := 0 to MaxSeries - 1 do
    SetLength(V[s], Cap);
  Cols := -1;

  P := 1;
  while P <= Length(Buf) do
  begin
    Q := PosEx(#10, Buf, P);
    if Q = 0 then Q := Length(Buf) + 1;
    Line := Copy(Buf, P, Q - P);
    P := Q + 1;
    if (Line <> '') and (Line[Length(Line)] = #13) then SetLength(Line, Length(Line) - 1);
    if Line = '' then Continue;

    if StartsText('Time', Line) then
    begin
      if Header = '' then
      begin
        Header := Line;
        Cols := Min(MaxSeries, Length(Line) - Length(StringReplace(Line, ';', '', [rfReplaceAll])));
      end;
      Continue;
    end;

    FieldEnd := Pos(';', Line);
    if FieldEnd = 0 then Continue;
    if not ParseTimeStr(Copy(Line, 1, FieldEnd - 1), TT, IsDbl) then Continue;
    if Cols < 0 then
      Cols := Min(MaxSeries, Length(Line) - Length(StringReplace(Line, ';', '', [rfReplaceAll])));
    if N = 0 then
      if IsDbl then TimeFmt := 'Double' else TimeFmt := 'Date-time';

    if N >= Cap then
    begin
      Cap := Cap * 2;
      SetLength(T, Cap);
      for s := 0 to MaxSeries - 1 do
        SetLength(V[s], Cap);
    end;
    T[N] := TT;
    for s := 0 to Cols - 1 do
    begin
      FieldStart := FieldEnd + 1;
      if FieldStart > Length(Line) + 1 then
      begin
        V[s][N] := NaN;
        Continue;
      end;
      FieldEnd := PosEx(';', Line, FieldStart);
      if FieldEnd = 0 then FieldEnd := Length(Line) + 1;
      V[s][N] := ParseValueStr(Copy(Line, FieldStart, FieldEnd - FieldStart));
    end;
    Inc(N);
  end;
  if (Header = '') and (Cols > 0) then
  begin
    Header := 'Time';
    for s := 1 to Cols do
      Header := Header + ';Set ' + IntToStr(s);
  end;
  Result := (N > 0) and (Cols > 0);
end;

procedure TfrmReader.SetupSeries(const Header: string; ColCount: Integer);
var
  Parts: TStringList;
  s: Integer;
begin
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Header;
    FSeriesCount := Min(ColCount, MaxSeries);
    for s := 0 to FSeriesCount - 1 do
    begin
      if s + 1 < Parts.Count then
        SplitHeaderName(Parts[s + 1], FSeries[s].Name, FSeries[s].Kind)
      else
      begin
        FSeries[s].Name := 'Set ' + IntToStr(s + 1);
        FSeries[s].Kind := dkDouble;
      end;
      if FSeries[s].Name = '' then FSeries[s].Name := 'Set ' + IntToStr(s + 1);
      FSeries[s].Color := FLine[s].Color;
      FSeries[s].Visible := FLine[s].Visible;
      FSeries[s].AxisUser := False;
    end;
  finally
    Parts.Free;
  end;
  BuildSeriesMenu;
end;

function HeaderColumns(const Header: string): Integer;
begin
  Result := Min(MaxSeries, Length(Header) - Length(StringReplace(Header, ';', '', [rfReplaceAll])));
end;

{ Open (Append = False) or add files; all samples are merged by time }
procedure TfrmReader.LoadFiles(Names: TStrings; Append: Boolean);
var
  i, s, N, Cols, NewCap: Integer;
  T: TTimeArray;
  V: TValueArrays;
  Header, Fmt, Problems: string;
  FI: TFileInfo;
  Y, Mo, D, H, Mi, Sec, MS: Word;
begin
  Screen.Cursor := crHourGlass;
  Problems := '';
  try
    if not Append then
    begin
      SetLength(FPins, 0);
      FCount := 0;
      FTimes := nil;
      for s := 0 to MaxSeries - 1 do FData[s] := nil;
      SetLength(FFiles, 0);
      FSeriesCount := 0;
    end;

    for i := 0 to Names.Count - 1 do
    begin
      FLblStatus.Caption := 'Reading ' + ExtractFileName(Names[i]) + ' ...';
      FLblStatus.Repaint;
      try
        if not ParseFile(Names[i], T, V, N, Header, Fmt) then
        begin
          Problems := Problems + ExtractFileName(Names[i]) + ': no samples found' + LineEnding;
          Continue;
        end;
      except
        on E: Exception do
        begin
          Problems := Problems + ExtractFileName(Names[i]) + ': ' + E.Message + LineEnding;
          Continue;
        end;
      end;
      Cols := HeaderColumns(Header);
      if FSeriesCount = 0 then
        SetupSeries(Header, Cols)
      else if Cols <> FSeriesCount then
      begin
        Problems := Problems + Format('%s: %d data sets, the open data has %d - skipped',
          [ExtractFileName(Names[i]), Cols, FSeriesCount]) + LineEnding;
        Continue;
      end;

      // append, sorted later
      NewCap := FCount + N;
      SetLength(FTimes, NewCap);
      for s := 0 to MaxSeries - 1 do
        SetLength(FData[s], NewCap);
      Move(T[0], FTimes[FCount], N * SizeOf(TDateTime));
      for s := 0 to FSeriesCount - 1 do
        Move(V[s][0], FData[s][FCount], N * SizeOf(Double));
      Inc(FCount, N);

      FI.FileName := Names[i];
      FI.Rows := N;
      FI.First := T[0];
      FI.Last := T[N - 1];
      FI.TimeFormat := Fmt;
      SetLength(FFiles, Length(FFiles) + 1);
      FFiles[High(FFiles)] := FI;
    end;

    SortAndDedupe;
    Analyse;
    BuildLOD;
    Inc(FDataVersion);
    SetLength(FZoomStack, 0);
    AutoAxes;
    ShowAll;
  finally
    Screen.Cursor := crDefault;
  end;
  UpdateInfo;
  UpdateStatus;
  RefreshPinGrid;
  if FCount > 0 then
  begin
    // pin time boxes start at the last sample
    DecodeDateTime(FTimes[FCount - 1], Y, Mo, D, H, Mi, Sec, MS);
    FPinSpins[0].Value := D;
    FPinSpins[1].Value := Mo;
    FPinSpins[2].Value := Y;
    FPinSpins[3].Value := H;
    FPinSpins[4].Value := Mi;
    FPinSpins[5].Value := Sec;
  end;
  if Problems <> '' then
    MessageDlg('Some files could not be used:' + LineEnding + LineEnding + Problems,
      mtWarning, [mbOK], 0);
end;

{ times ascending, equal times only once (e.g. a daily file and the main
  file opened together) }
procedure TfrmReader.SortAndDedupe;
var
  Idx: array of Integer;
  i, j, s, Keep: Integer;
  Sorted: Boolean;
  NT: TTimeArray;
  ND: TDoubleArray;

  procedure QSort(L, R: Integer);
  var
    I, J, Tmp: Integer;
    Pivot: TDateTime;
  begin
    repeat
      I := L;
      J := R;
      Pivot := FTimes[Idx[(L + R) shr 1]];
      repeat
        while FTimes[Idx[I]] < Pivot do Inc(I);
        while FTimes[Idx[J]] > Pivot do Dec(J);
        if I <= J then
        begin
          Tmp := Idx[I]; Idx[I] := Idx[J]; Idx[J] := Tmp;
          Inc(I);
          Dec(J);
        end;
      until I > J;
      if L < J then QSort(L, J);
      L := I;
    until I >= R;
  end;

begin
  if FCount < 2 then Exit;
  Sorted := True;
  for i := 1 to FCount - 1 do
    if FTimes[i] <= FTimes[i - 1] then
    begin
      Sorted := False;
      Break;
    end;
  if Sorted then Exit;

  SetLength(Idx, FCount);
  for i := 0 to FCount - 1 do Idx[i] := i;
  QSort(0, FCount - 1);

  // drop equal times (less than 0.5 ms apart)
  Keep := 0;
  for i := 0 to FCount - 1 do
    if (Keep = 0) or (FTimes[Idx[i]] - FTimes[Idx[Keep - 1]] > OneMillisecond / 2) then
    begin
      Idx[Keep] := Idx[i];
      Inc(Keep);
    end;

  SetLength(NT, Keep);
  for j := 0 to Keep - 1 do NT[j] := FTimes[Idx[j]];
  for s := 0 to FSeriesCount - 1 do
  begin
    ND := nil;
    SetLength(ND, Keep);
    for j := 0 to Keep - 1 do ND[j] := FData[s][Idx[j]];
    FData[s] := ND;
  end;
  FTimes := NT;
  FCount := Keep;
end;

{ sample interval (median of the first differences) and gaps }
procedure TfrmReader.Analyse;
var
  D: array of Double;
  i, n: Integer;
  Diff: Double;
begin
  FIntervalMs := 0;
  FGapCount := 0;
  FLongestGap := 0;
  FGapSeconds := 3;
  if FCount < 2 then Exit;
  n := Min(FCount - 1, 20000);
  SetLength(D, n);
  for i := 0 to n - 1 do
    D[i] := (FTimes[i + 1] - FTimes[i]) * MSecsPerDay;
  // median by sorting a copy (small)
  for i := 1 to n - 1 do
  begin
    Diff := D[i];
    n := i - 1;
    while (n >= 0) and (D[n] > Diff) do
    begin
      D[n + 1] := D[n];
      Dec(n);
    end;
    D[n + 1] := Diff;
  end;
  FIntervalMs := D[Length(D) div 2];
  FGapSeconds := Max(1.0, FIntervalMs * 3 / 1000);
  for i := 1 to FCount - 1 do
  begin
    Diff := (FTimes[i] - FTimes[i - 1]) * SecsPerDay;
    if Diff > FGapSeconds then
    begin
      Inc(FGapCount);
      if Diff > FLongestGap then FLongestGap := Diff;
    end;
  end;
end;

{ ---------- info ---------- }

procedure TfrmReader.UpdateInfo;
var
  i, Row: Integer;
  Size: Int64;
  SR: TSearchRec;

  procedure AddRow(const AName, AValue: string);
  begin
    FSummaryGrid.RowCount := Row + 1;
    FSummaryGrid.Cells[0, Row] := AName;
    FSummaryGrid.Cells[1, Row] := AValue;
    Inc(Row);
  end;

begin
  // files
  FFilesGrid.RowCount := 1 + Length(FFiles);
  Size := 0;
  for i := 0 to High(FFiles) do
  begin
    FFilesGrid.Cells[0, i + 1] := ExtractFileName(FFiles[i].FileName);
    FFilesGrid.Cells[1, i + 1] := IntToStr(FFiles[i].Rows);
    FFilesGrid.Cells[2, i + 1] := FormatDateTime('dd/mm hh:nn:ss', FFiles[i].First);
    FFilesGrid.Cells[3, i + 1] := FormatDateTime('dd/mm hh:nn:ss', FFiles[i].Last);
    FFilesGrid.Cells[4, i + 1] := FFiles[i].TimeFormat;
    if FindFirst(FFiles[i].FileName, faAnyFile, SR) = 0 then
    begin
      Inc(Size, SR.Size);
      FindClose(SR);
    end;
  end;

  // summary
  Row := 1;
  FSummaryGrid.RowCount := 1;
  if FCount = 0 then
  begin
    AddRow('Samples', 'no data - File > Open');
  end
  else
  begin
    AddRow('Files', Format('%d  (%s)', [Length(FFiles), FormatBytes(Size)]));
    AddRow('Samples', IntToStr(FCount));
    AddRow('Data sets', IntToStr(FSeriesCount));
    AddRow('First sample', FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FTimes[0]));
    AddRow('Last sample', FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FTimes[FCount - 1]));
    AddRow('Duration', FormatDuration((FTimes[FCount - 1] - FTimes[0]) * SecsPerDay));
    AddRow('Sample interval', FormatFloat('0.#', FIntervalMs) + ' ms (median)');
    AddRow('Gaps', Format('%d (longer than %s)', [FGapCount, FormatDuration(FGapSeconds)]));
    if FGapCount > 0 then
      AddRow('Longest gap', FormatDuration(FLongestGap));
    AddRow('Days', IntToStr(Trunc(FTimes[FCount - 1]) - Trunc(FTimes[0]) + 1));
  end;
  UpdateStats;
end;

{ count / min / max / mean / standard deviation per data set }
procedure TfrmReader.UpdateStats;
var
  s, i, i0, i1, Cnt: Integer;
  V, Mn, Mx, Mean, M2, Delta: Double;
begin
  FStatsGrid.RowCount := 1 + FSeriesCount;
  FStatsBox.Height := Max(120, 74 + (1 + FSeriesCount) * 23);
  if FCount = 0 then Exit;
  if FChkStatsView.Checked then
  begin
    i0 := LowerBound(ViewStart);
    i1 := LowerBound(FViewEnd + OneMillisecond) - 1;
  end
  else
  begin
    i0 := 0;
    i1 := FCount - 1;
  end;
  for s := 0 to FSeriesCount - 1 do
  begin
    // prefix sums + min/max pyramid: no loop over the samples
    RangeSums(s, i0, i1, V, Delta, Cnt);
    if Cnt > 0 then Mean := V / Cnt else Mean := 0;
    M2 := Max(0, Delta - V * V / Max(1, Cnt));
    if not RangeMinMax(s, i0, i1, Mn, Mx) then
    begin
      Mn := 0;
      Mx := 0;
    end;
    FStatsGrid.Cells[0, s + 1] := FSeries[s].Name;
    FStatsGrid.Cells[1, s + 1] := KindNames[FSeries[s].Kind];
    FStatsGrid.Cells[2, s + 1] := IntToStr(Cnt);
    if Cnt = 0 then
    begin
      for i := 3 to 6 do FStatsGrid.Cells[i, s + 1] := '-';
      Continue;
    end;
    if FSeries[s].Kind = dkBoolean then
    begin
      FStatsGrid.Cells[3, s + 1] := DisplayValue(s, Mn);
      FStatsGrid.Cells[4, s + 1] := DisplayValue(s, Mx);
      FStatsGrid.Cells[5, s + 1] := FormatFloat('0.0', Mean * 100) + '% true';
    end
    else
    begin
      FStatsGrid.Cells[3, s + 1] := FormatFloat('0.###', Mn);
      FStatsGrid.Cells[4, s + 1] := FormatFloat('0.###', Mx);
      FStatsGrid.Cells[5, s + 1] := FormatFloat('0.###', Mean);
    end;
    if Cnt > 1 then
      FStatsGrid.Cells[6, s + 1] := FormatFloat('0.###', Sqrt(M2 / (Cnt - 1)))
    else
      FStatsGrid.Cells[6, s + 1] := '-';
  end;
end;

{ ---------- view ---------- }

function TfrmReader.FirstTime: TDateTime;
begin
  if FCount > 0 then Result := FTimes[0] else Result := Now - FViewSpan;
end;

function TfrmReader.LastTime: TDateTime;
begin
  if FCount > 0 then Result := FTimes[FCount - 1] else Result := Now;
end;

function TfrmReader.ViewStart: TDateTime;
begin
  Result := FViewEnd - FViewSpan;
end;

function TfrmReader.LowerBound(T: TDateTime): Integer;
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

function TfrmReader.NearestIndex(T: TDateTime): Integer;
begin
  Result := -1;
  if FCount = 0 then Exit;
  Result := Min(LowerBound(T), FCount - 1);
  if (Result > 0) and (Abs(FTimes[Result - 1] - T) < Abs(FTimes[Result] - T)) then
    Dec(Result);
end;

procedure TfrmReader.AutoAxes;
var
  s: Integer;
  Lo, Hi, V, Pad: Double;
begin
  Lo := Infinity;
  Hi := -Infinity;
  for s := 0 to FSeriesCount - 1 do
    if (FSeries[s].Kind <> dkBoolean) and (FCount > 0) and RangeMinMax(s, 0, FCount - 1, V, Pad) then
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

procedure TfrmReader.ShowAll;
begin
  FViewSpan := Max(LastTime - FirstTime, MinSpanSeconds * OneSecond);
  FViewEnd := LastTime;
  SyncWindowCombo;
  SetView(FViewEnd);
end;

procedure TfrmReader.SetView(AEnd: TDateTime);
var
  TS, TE: TDateTime;
begin
  TS := FirstTime;
  TE := LastTime;
  if FViewSpan > TE - TS then FViewSpan := Max(TE - TS, MinSpanSeconds * OneSecond);
  if AEnd > TE then AEnd := TE;
  if AEnd - FViewSpan < TS then AEnd := Min(TE, TS + FViewSpan);
  FViewEnd := AEnd;
  UpdateScrollBar;
  UpdateStatus;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.SetSpan(ASpan: TDateTime; AnchorX: Integer);
var
  R: TRect;
  Frac, Anchor: Double;
begin
  ASpan := EnsureRange(ASpan, MinSpanSeconds * OneSecond, Max(LastTime - FirstTime, OneSecond));
  R := PlotRect;
  if (AnchorX < 0) or (R.Width <= 0) then
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

procedure TfrmReader.SyncWindowCombo;
var
  i, Idx: Integer;
begin
  Idx := -1;
  for i := Low(WindowSeconds) to High(WindowSeconds) - 1 do
    if Abs(FViewSpan * SecsPerDay - WindowSeconds[i]) < 0.5 then Idx := i;
  if (Idx < 0) and (FCount > 1) and
     (Abs(FViewSpan - (LastTime - FirstTime)) * SecsPerDay < 0.5) then
    Idx := High(WindowSeconds);     // All
  if FCmbWindow.ItemIndex <> Idx then FCmbWindow.ItemIndex := Idx;
end;

procedure TfrmReader.UpdateScrollBar;
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

procedure TfrmReader.UpdateStatus;
var
  S: string;
begin
  if FCount = 0 then
    S := 'Open CSV files from HistoryRandomData (File > Open, or drop them on the window)'
  else
  begin
    S := Format('%d samples  |  view %s - %s', [FCount,
      FormatDateTime('dd/mm/yyyy hh:nn:ss', ViewStart),
      FormatDateTime('dd/mm/yyyy hh:nn:ss', FViewEnd)]);
    if Length(FZoomStack) > 0 then
      S := S + Format('  |  zoom level %d (Ctrl+Z = undo)', [Length(FZoomStack)]);
  end;
  FLblStatus.Caption := S;
  if FChkStatsView.Checked then UpdateStats;
  UpdateDataGrid;
end;

{ ---------- data grid ---------- }

procedure TfrmReader.UpdateDataGrid(Columns: Boolean);
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
    UpdateGridColors;
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
    Format('%d samples in view', [Max(0, Last - FGridFirst + 1)]), False);
end;

function TfrmReader.DataGridCell(Row, Col: Integer): string;
var
  i: Integer;
begin
  Result := '';
  i := FGridFirst + Row;
  if (i < 0) or (i >= FCount) then Exit;
  case Col of
    0: Result := IntToStr(i + 1);
    1: Result := FDataGrid.FormatTime(FTimes[i]);
  else
    if Col - 2 < FSeriesCount then
      Result := FDataGrid.FormatValue(FData[Col - 2][i], Ord(FSeries[Col - 2].Kind));
  end;
end;

{ value colours = line colours of the data sets }
procedure TfrmReader.UpdateGridColors;
var
  Cols: array of TColor;
  s: Integer;
begin
  SetLength(Cols, 2 + FSeriesCount);
  Cols[0] := clNone;
  Cols[1] := clNone;
  for s := 0 to FSeriesCount - 1 do
    Cols[2 + s] := RGBToColor(FLine[s].Color.red, FLine[s].Color.green, FLine[s].Color.blue);
  FDataGrid.SetColumnColors(Cols);
  if FCount > 0 then FDataGrid.TimeBase := FTimes[0];
end;

procedure TfrmReader.DataGridOptionsChange(Sender: TObject);
begin
  UpdateGridColors;
  UpdateDataGrid;
end;

procedure TfrmReader.DataGridRowDblClick(Sender: TObject; Row: Integer);
var
  i: Integer;
begin
  i := FGridFirst + Row;
  if (i < 0) or (i >= FCount) then Exit;
  SetView(FTimes[i] + FViewSpan / 2);
end;

{ ---------- lines ---------- }

{ one row per data set: colour, name, style list, thickness }
procedure TfrmReader.InitLine(S: Integer);
begin
  with FLine[S] do
  begin
    Visible := True;
    Color := Palette[S];
    Opacity := 100;
    Style := psSolid;
    Width := 1.5;
    Mode := lmLine;
    Marker := mkNone;
    MarkerSize := 6;
  end;
end;

{ colour with the opacity of the data set }
function TfrmReader.LineColor(S: Integer): TBGRAPixel;
begin
  Result := FLine[S].Color;
  Result.alpha := EnsureRange(Round(FLine[S].Opacity * 2.55), 10, 255);
end;

{ one group per data set: visible, colour, opacity / style, thickness /
  draw mode, marker, marker size }
procedure TfrmReader.BuildLineRows;
var
  i, s: Integer;
  Grp: TGroupBox;
  Bar: TPanel;
  Btn: TButton;
  Chk: TCheckBox;
  CB: TColorButton;
  Cmb: TComboBox;
  FSp: TFloatSpinEdit;
  ISp: TSpinEdit;
  M: TLineMode;
  K: TMarkerKind;

  procedure Track(C: TControl);
  begin
    FLineControls.Add(C);
  end;

  function AddLabel(AParent: TWinControl; X, Y: Integer; const ACaption: string): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := AParent;
    Result.SetBounds(X, Y + 4, 50, 18);
    Result.Caption := ACaption;
  end;

  function AddCombo(AParent: TWinControl; X, Y, W: Integer; const Items: array of string;
    AIndex: Integer; AHandler: TNotifyEvent): TComboBox;
  var
    j: Integer;
  begin
    Result := TComboBox.Create(Self);
    Result.Parent := AParent;
    Result.SetBounds(X, Y, W, 24);
    Result.Style := csDropDownList;
    for j := 0 to High(Items) do Result.Items.Add(Items[j]);
    Result.ItemIndex := AIndex;
    Result.Tag := s;
    Result.OnChange := AHandler;
  end;

  function AddFloat(AParent: TWinControl; X, Y, W: Integer; AMin, AMax, AInc, AValue: Double;
    AHandler: TNotifyEvent): TFloatSpinEdit;
  begin
    Result := TFloatSpinEdit.Create(Self);
    Result.Parent := AParent;
    Result.SetBounds(X, Y, W, 24);
    Result.MinValue := AMin;
    Result.MaxValue := AMax;
    Result.Increment := AInc;
    Result.DecimalPlaces := 1;
    Result.Value := AValue;
    Result.Tag := s;
    Result.OnChange := AHandler;
  end;

begin
  if FLinesBox = nil then Exit;
  FUpdatingLines := True;
  try
    for i := FLineControls.Count - 1 downto 0 do
      TControl(FLineControls[i]).Free;
    FLineControls.Clear;
    for s := 0 to MaxSeries - 1 do
      FLineVisChk[s] := nil;

    // reset button
    // fixed positions (alTop order is not reliable when rebuilding)
    Bar := TPanel.Create(Self);
    Bar.Parent := FLinesBox;
    Bar.SetBounds(0, 0, FLinesBox.ClientWidth, 32);
    Bar.Anchors := [akLeft, akTop, akRight];
    Bar.BevelOuter := bvNone;
    Track(Bar);
    Btn := TButton.Create(Self);
    Btn.Parent := Bar;
    Btn.SetBounds(6, 3, 130, 26);
    Btn.Caption := 'Reset all lines';
    Btn.OnClick := @BtnResetLinesClick;

    for s := 0 to FSeriesCount - 1 do
    begin
      Grp := TGroupBox.Create(Self);
      Grp.Parent := FLinesBox;
      Grp.SetBounds(2, 34 + s * (LineGroupHeight + 2), FLinesBox.ClientWidth - 4, LineGroupHeight);
      Grp.Anchors := [akLeft, akTop, akRight];
      Grp.Caption := Format(' Y%d: %s ', [s + 1, FSeries[s].Name]);
      Track(Grp);

      // row 1: visible, colour, opacity
      Chk := TCheckBox.Create(Self);
      Chk.Parent := Grp;
      Chk.SetBounds(8, 4, 70, 20);
      Chk.Caption := 'Visible';
      Chk.Checked := FLine[s].Visible;
      Chk.Tag := s;
      Chk.OnChange := @LineVisibleChange;
      FLineVisChk[s] := Chk;

      CB := TColorButton.Create(Self);
      CB.Parent := Grp;
      CB.SetBounds(84, 0, 92, 26);
      CB.Caption := 'Colour';
      CB.ButtonColor := RGBToColor(FLine[s].Color.red, FLine[s].Color.green, FLine[s].Color.blue);
      CB.Tag := s;
      CB.OnColorChanged := @LineColorChange;

      AddLabel(Grp, 192, 0, 'Opacity');
      ISp := TSpinEdit.Create(Self);
      ISp.Parent := Grp;
      ISp.SetBounds(246, 0, 64, 24);
      ISp.MinValue := 10;
      ISp.MaxValue := 100;
      ISp.Increment := 10;
      ISp.Value := FLine[s].Opacity;
      ISp.Tag := s;
      ISp.Hint := 'Opacity in %';
      ISp.ShowHint := True;
      ISp.OnChange := @LineOpacityChange;
      AddLabel(Grp, 314, 0, '%');

      // row 2: style, thickness
      AddLabel(Grp, 8, 30, 'Style');
      Cmb := AddCombo(Grp, 52, 30, 124, LineStyleNames, 0, @LineStyleChange);
      for i := Low(LineStyles) to High(LineStyles) do
        if LineStyles[i] = FLine[s].Style then Cmb.ItemIndex := i;
      AddLabel(Grp, 192, 30, 'Width');
      FSp := AddFloat(Grp, 246, 30, 64, 0.5, 8, 0.5, FLine[s].Width, @LineWidthChange);
      FSp.Hint := 'Line thickness (pixels)';
      FSp.ShowHint := True;

      // row 3: draw mode, marker, marker size
      AddLabel(Grp, 8, 60, 'Draw');
      Cmb := AddCombo(Grp, 52, 60, 124, [], Ord(FLine[s].Mode), @LineModeChange);
      for M := Low(TLineMode) to High(TLineMode) do Cmb.Items.Add(LineModeNames[M]);
      Cmb.ItemIndex := Ord(FLine[s].Mode);
      Cmb.Hint := 'Line, steps (value holds until the next sample) or points only';
      Cmb.ShowHint := True;
      AddLabel(Grp, 192, 60, 'Marker');
      Cmb := AddCombo(Grp, 246, 60, 90, [], Ord(FLine[s].Marker), @LineMarkerChange);
      for K := Low(TMarkerKind) to High(TMarkerKind) do Cmb.Items.Add(MarkerNames[K]);
      Cmb.ItemIndex := Ord(FLine[s].Marker);
      Cmb.Hint := 'Marker on every sample (shown when zoomed in far enough)';
      Cmb.ShowHint := True;
      FSp := AddFloat(Grp, 340, 60, 60, 2, 20, 1, FLine[s].MarkerSize, @LineMarkerSizeChange);
      FSp.Hint := 'Marker size (pixels)';
      FSp.ShowHint := True;
    end;
    FLinesBox.Height := 58 + FSeriesCount * (LineGroupHeight + 2);
  finally
    FUpdatingLines := False;
  end;
end;

procedure TfrmReader.LineVisibleChange(Sender: TObject);
var
  S: Integer;
begin
  if FUpdatingLines then Exit;
  S := TCheckBox(Sender).Tag;
  FLine[S].Visible := TCheckBox(Sender).Checked;
  FSeries[S].Visible := FLine[S].Visible;
  if S < FMnuSeries.Count then
    FMnuSeries.Items[S].Checked := FLine[S].Visible;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.LineColorChange(Sender: TObject);
var
  S: Integer;
  C: TColor;
begin
  if FUpdatingLines then Exit;
  S := TColorButton(Sender).Tag;
  C := ColorToRGB(TColorButton(Sender).ButtonColor);
  FLine[S].Color := BGRA(Red(C), Green(C), Blue(C));
  FSeries[S].Color := FLine[S].Color;
  UpdateGridColors;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.LineOpacityChange(Sender: TObject);
begin
  if FUpdatingLines then Exit;
  FLine[TSpinEdit(Sender).Tag].Opacity := TSpinEdit(Sender).Value;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.LineStyleChange(Sender: TObject);
var
  Idx: Integer;
begin
  if FUpdatingLines then Exit;
  Idx := TComboBox(Sender).ItemIndex;
  if (Idx < Low(LineStyles)) or (Idx > High(LineStyles)) then Exit;
  FLine[TComboBox(Sender).Tag].Style := LineStyles[Idx];
  FPaintBox.Invalidate;
end;

procedure TfrmReader.LineWidthChange(Sender: TObject);
begin
  if FUpdatingLines then Exit;
  FLine[TFloatSpinEdit(Sender).Tag].Width := TFloatSpinEdit(Sender).Value;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.LineModeChange(Sender: TObject);
begin
  if FUpdatingLines or (TComboBox(Sender).ItemIndex < 0) then Exit;
  FLine[TComboBox(Sender).Tag].Mode := TLineMode(TComboBox(Sender).ItemIndex);
  FPaintBox.Invalidate;
end;

procedure TfrmReader.LineMarkerChange(Sender: TObject);
begin
  if FUpdatingLines or (TComboBox(Sender).ItemIndex < 0) then Exit;
  FLine[TComboBox(Sender).Tag].Marker := TMarkerKind(TComboBox(Sender).ItemIndex);
  FPaintBox.Invalidate;
end;

procedure TfrmReader.LineMarkerSizeChange(Sender: TObject);
begin
  if FUpdatingLines then Exit;
  FLine[TFloatSpinEdit(Sender).Tag].MarkerSize := TFloatSpinEdit(Sender).Value;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.InfoGridWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
begin
  FInfoPanel.VertScrollBar.Position := FInfoPanel.VertScrollBar.Position - WheelDelta div 2;
  Handled := True;
end;

procedure TfrmReader.AsyncBuildLines(Data: PtrInt);
begin
  BuildLineRows;
end;

procedure TfrmReader.BtnResetLinesClick(Sender: TObject);
var
  S: Integer;
begin
  for S := 0 to MaxSeries - 1 do
    InitLine(S);
  for S := 0 to FSeriesCount - 1 do
  begin
    FSeries[S].Color := FLine[S].Color;
    FSeries[S].Visible := True;
    if S < FMnuSeries.Count then FMnuSeries.Items[S].Checked := True;
  end;
  // rebuilt after this click event has finished
  Application.QueueAsyncCall(@AsyncBuildLines, 0);
  FPaintBox.Invalidate;
end;

{ ---------- chart panel ---------- }

{$ifdef windows}
type
  TProcessMemoryCounters = record
    cb: LongWord;
    PageFaultCount: LongWord;
    PeakWorkingSetSize, WorkingSetSize: PtrUInt;
    QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage: PtrUInt;
    QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage: PtrUInt;
    PagefileUsage, PeakPagefileUsage: PtrUInt;
  end;

function GetProcessMemoryInfo(Process: THandle; var Counters: TProcessMemoryCounters;
  cb: LongWord): LongBool; stdcall; external 'psapi.dll';
function GetCurrentProcess: THandle; stdcall; external 'kernel32.dll';
function QueryPerformanceCounter(out Count: Int64): LongBool; stdcall; external 'kernel32.dll';
function QueryPerformanceFrequency(out Freq: Int64): LongBool; stdcall; external 'kernel32.dll';
{$endif}

procedure TfrmReader.BuildChartPanel;
var
  Bar: TPanel;
  Btn: TButton;
  Lbl: TLabel;
begin
  FPropKeys := TStringList.Create;

  FChartPanel := TPanel.Create(Self);
  FChartPanel.Parent := Self;
  FChartPanel.Align := alLeft;
  FChartPanel.Width := 380;
  FChartPanel.BevelOuter := bvNone;
  FChartPanel.Visible := False;

  Bar := TPanel.Create(Self);
  Bar.Parent := FChartPanel;
  Bar.Align := alTop;
  Bar.Height := 32;
  Bar.BevelOuter := bvNone;
  Lbl := TLabel.Create(Self);
  Lbl.Parent := Bar;
  Lbl.SetBounds(6, 8, 200, 18);
  Lbl.Caption := 'Chart - blue values can be edited';
  Lbl.Font.Style := [fsBold];
  Btn := TButton.Create(Self);
  Btn.Parent := Bar;
  Btn.Align := alRight;
  Btn.Width := 80;
  Btn.BorderSpacing.Around := 3;
  Btn.Caption := 'Copy';
  Btn.Hint := 'Copy all chart information as text';
  Btn.ShowHint := True;
  Btn.OnClick := @BtnCopyPropsClick;

  FPropGrid := TStringGrid.Create(Self);
  FPropGrid.Parent := FChartPanel;
  FPropGrid.Align := alClient;
  FPropGrid.FixedCols := 0;
  FPropGrid.FixedRows := 1;
  FPropGrid.ColCount := 2;
  FPropGrid.RowCount := 1;
  FPropGrid.DefaultRowHeight := 21;
  FPropGrid.Options := FPropGrid.Options + [goColSizing, goAlwaysShowEditor] - [goRangeSelect];
  FPropGrid.Cells[0, 0] := 'Property';
  FPropGrid.Cells[1, 0] := 'Value';
  FPropGrid.ColWidths[0] := 160;
  FPropGrid.ColWidths[1] := 196;
  FPropGrid.OnSelectCell := @PropSelectCell;
  FPropGrid.OnValidateEntry := @PropValidate;
  FPropGrid.OnPrepareCanvas := @PropPrepareCanvas;
  FPropGrid.OnMouseWheel := @PropGridWheel;

  FChartSplitter := TSplitter.Create(Self);
  FChartSplitter.Parent := Self;
  FChartSplitter.Align := alLeft;
  FChartSplitter.Left := FChartPanel.Left + FChartPanel.Width + 1;
  FChartSplitter.Visible := False;

  FPropTimer := TTimer.Create(Self);
  FPropTimer.Interval := 500;
  FPropTimer.Enabled := False;
  FPropTimer.OnTimer := @PropTimerTick;
end;

procedure TfrmReader.MnuChartClick(Sender: TObject);
begin
  FMnuChart.Checked := not FMnuChart.Checked;
  FChartPanel.Visible := FMnuChart.Checked;
  FChartSplitter.Visible := FMnuChart.Checked;
  if FChartPanel.Visible then
  begin
    FChartPanel.Left := 0;
    FChartSplitter.Left := FChartPanel.Width + 1;
    RefreshChartPanel;
  end;
  FPropTimer.Enabled := FChartPanel.Visible;
end;

procedure TfrmReader.PropTimerTick(Sender: TObject);
begin
  RefreshChartPanel;
end;

function YesNo(B: Boolean): string;
begin
  if B then Result := 'Yes' else Result := 'No';
end;

procedure TfrmReader.RefreshChartPanel;
var
  Row, s, i, i0, i1, Cnt, NaNs, Gaps, VisAxes, Idx: Integer;
  R: TRect;
  SpanSec, T, V: Double;
  MemTimes, MemTimesCap, MemData, MemDataCap, MemBmp: Int64;
  HS: TFPCHeapStatus;
  Mode, Hover: string;
  {$ifdef windows}
  PMC: TProcessMemoryCounters;
  {$endif}

  procedure Add(const Key, AName, AValue: string);
  begin
    if Row >= FPropGrid.RowCount then FPropGrid.RowCount := Row + 1;
    FPropKeys.Add(Key);
    FPropGrid.Cells[0, Row] := AName;
    // do not overwrite the cell that is being edited
    if not (FPropGrid.EditorMode and (FPropGrid.Row = Row)) then
      FPropGrid.Cells[1, Row] := AValue;
    Inc(Row);
  end;

  procedure Section(const ATitle: string);
  begin
    Add('#', ATitle, '');
  end;

  function Bytes(B: Int64): string;
  begin
    Result := FormatBytes(B);
  end;

begin
  if (FChartPanel = nil) or not FChartPanel.Visible then Exit;
  FPropKeys.Clear;
  FPropKeys.Add('#');       // title row
  Row := 1;
  R := PlotRect;
  SpanSec := FViewSpan * SecsPerDay;
  if FCount > 0 then
  begin
    i0 := LowerBound(ViewStart);
    i1 := LowerBound(FViewEnd + OneMillisecond) - 1;
  end
  else
  begin
    i0 := 0;
    i1 := -1;
  end;

  // ---- properties (editable)
  Section('PROPERTIES');
  Add('from', 'View from', FormatDateTime('dd/mm/yyyy hh:nn:ss', ViewStart));
  Add('to', 'View to', FormatDateTime('dd/mm/yyyy hh:nn:ss', FViewEnd));
  Add('span', 'Span (seconds)', FormatFloat('0.###', SpanSec));
  Add('grid', 'Grid lines', YesNo(FShowGrid));
  Add('gap', 'Gap threshold (s)', FormatFloat('0.###', FGapSeconds));
  for s := 0 to FSeriesCount - 1 do
  begin
    Add('vis' + IntToStr(s), Format('Y%d visible', [s + 1]), YesNo(FSeries[s].Visible));
    Add('ymin' + IntToStr(s), Format('Y%d axis min', [s + 1]), FormatFloat('0.###', FSeries[s].AxisMin));
    Add('ymax' + IntToStr(s), Format('Y%d axis max', [s + 1]), FormatFloat('0.###', FSeries[s].AxisMax));
  end;

  // ---- detail
  Section('DETAIL');
  Add('', 'Chart size', Format('%d x %d px', [FPaintBox.Width, FPaintBox.Height]));
  Add('', 'Plot area', Format('%d x %d px at (%d, %d)', [R.Width, R.Height, R.Left, R.Top]));
  Add('', 'Window preset', IfThen(FCmbWindow.ItemIndex >= 0, FCmbWindow.Text, 'custom'));
  Add('', 'Duration in view', FormatDuration(SpanSec));
  if R.Width > 0 then
  begin
    Add('', 'Time per pixel', FormatFloat('0.###', SpanSec / R.Width) + ' s');
    Add('', 'Samples per pixel', FormatFloat('0.##', (i1 - i0 + 1) / R.Width));
  end;
  Add('', 'Time grid step', FormatDuration(FLastTimeStep));
  VisAxes := 0;
  for s := 0 to FSeriesCount - 1 do
    if FSeries[s].Visible then Inc(VisAxes);
  Add('', 'Data sets / visible', Format('%d / %d', [FSeriesCount, VisAxes]));
  Add('', 'Zoom level', IntToStr(Length(FZoomStack)));
  Add('', 'Pins', IntToStr(Length(FPins)));
  for s := 0 to FSeriesCount - 1 do
    Add('', Format('Y%d line', [s + 1]), Format('%s, %s %.1f px, %d %%',
      [LineModeNames[FLine[s].Mode], LineStyleNames[EnsureRange(Ord(FLine[s].Style), 0, 4)],
       FLine[s].Width, FLine[s].Opacity]));

  // ---- status
  Section('STATUS');
  if FSelecting then Mode := 'zoom box'
  else if FDragging then Mode := 'scrolling'
  else if FAxisDrag >= 0 then Mode := Format('moving Y%d axis', [FAxisDrag + 1])
  else Mode := 'idle';
  Add('', 'Mouse', Mode);
  Hover := '-';
  if (FCount > 0) and (FHoverX >= R.Left) and (FHoverX < R.Right) and (R.Width > 0) then
  begin
    T := ViewStart + (FHoverX - R.Left) / R.Width * FViewSpan;
    Idx := NearestIndex(T);
    Hover := FormatDateTime('dd/mm hh:nn:ss.zzz', T);
    if Idx >= 0 then Hover := Hover + Format('  (sample %d)', [Idx + 1]);
  end;
  Add('', 'Hover', Hover);
  Add('', 'Files loaded', IntToStr(Length(FFiles)));
  Add('', 'Paints', IntToStr(FPaintCount));
  Add('', 'Layer cache', Format('%d hits / %d renders', [FCacheHits, FCacheMisses]));
  Add('', 'Last paint', FormatFloat('0.00', FLastPaintMs) + ' ms');
  if FPaintCount > 0 then
    Add('', 'Average paint', FormatFloat('0.00', FTotalPaintMs / FPaintCount) + ' ms');

  // ---- data samples
  Section('DATA SAMPLES');
  Add('', 'Total samples', IntToStr(FCount));
  Add('', 'Visible samples', IntToStr(Max(0, i1 - i0 + 1)));
  if i1 >= i0 then
  begin
    Add('', 'First visible', FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FTimes[i0]));
    Add('', 'Last visible', FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FTimes[i1]));
    Gaps := GapsBetween(i0, i1);
    Add('', 'Gaps in view', IntToStr(Gaps));
  end;
  for s := 0 to FSeriesCount - 1 do
  begin
    RangeSums(s, i0, i1, V, T, Cnt);
    NaNs := Max(0, i1 - i0 + 1) - Cnt;
    Add('', Format('Y%d values / missing', [s + 1]), Format('%d / %d', [Cnt, NaNs]));
    if FDense[s] then
      Add('', Format('Y%d drawn', [s + 1]), Format('%d pixel columns (column rendering)', [FDrawn[s]]))
    else
      Add('', Format('Y%d drawn', [s + 1]), Format('%d points (antialiased)', [FDrawn[s]]));
  end;

  // ---- memory
  Section('MEMORY');
  MemTimes := Int64(FCount) * SizeOf(TDateTime);
  MemTimesCap := Int64(Length(FTimes)) * SizeOf(TDateTime);
  MemData := Int64(FCount) * FSeriesCount * SizeOf(Double);
  MemDataCap := 0;
  for s := 0 to MaxSeries - 1 do
    Inc(MemDataCap, Int64(Length(FData[s])) * SizeOf(Double));
  MemBmp := Int64(FPaintBox.Width) * FPaintBox.Height * 4;
  Add('', 'Time array', Bytes(MemTimes) + ' used / ' + Bytes(MemTimesCap) + ' reserved');
  Add('', 'Value arrays', Bytes(MemData) + ' used / ' + Bytes(MemDataCap) + ' reserved');
  Add('', 'Data total', Bytes(MemTimesCap + MemDataCap));
  Add('', 'LOD pyramid + prefix sums', Bytes(LodBytes) + Format(' (%d levels)', [Length(FLodSize)]));
  if FCache <> nil then
    Add('', 'Layer cache bitmap', Bytes(Int64(FCache.Width) * FCache.Height * 4));
  Add('', 'Pins / zoom history', Bytes(Int64(Length(FPins)) * SizeOf(TDateTime) +
    Int64(Length(FZoomStack)) * SizeOf(TZoomState)));
  Add('', 'Chart bitmap', Bytes(MemBmp) + Format(' (%d x %d x 4)', [FPaintBox.Width, FPaintBox.Height]));
  HS := GetFPCHeapStatus;
  Add('', 'Heap used (FPC)', Bytes(HS.CurrHeapUsed));
  Add('', 'Heap size (FPC)', Bytes(HS.CurrHeapSize));
  {$ifdef windows}
  FillChar(PMC, SizeOf(PMC), 0);
  PMC.cb := SizeOf(PMC);
  if GetProcessMemoryInfo(GetCurrentProcess, PMC, SizeOf(PMC)) then
  begin
    Add('', 'Process working set', Bytes(PMC.WorkingSetSize));
    Add('', 'Process peak', Bytes(PMC.PeakWorkingSetSize));
    Add('', 'Process private', Bytes(PMC.PagefileUsage));
  end;
  {$endif}

  FPropGrid.RowCount := Row;
end;

{ only the value column of editable rows can be edited }
procedure TfrmReader.PropSelectCell(Sender: TObject; aCol, aRow: Integer;
  var CanSelect: Boolean);
var
  Key: string;
begin
  Key := '';
  if aRow < FPropKeys.Count then Key := FPropKeys[aRow];
  if (aCol = 1) and (Key <> '') and (Key <> '#') then
    FPropGrid.Options := FPropGrid.Options + [goEditing]
  else
    FPropGrid.Options := FPropGrid.Options - [goEditing];
end;

procedure TfrmReader.PropPrepareCanvas(Sender: TObject; aCol, aRow: Integer;
  aState: TGridDrawState);
var
  Key: string;
begin
  if aRow = 0 then Exit;
  Key := '';
  if aRow < FPropKeys.Count then Key := FPropKeys[aRow];
  if Key = '#' then
  begin
    FPropGrid.Canvas.Font.Style := [fsBold];
    if not (gdSelected in aState) then
      FPropGrid.Canvas.Brush.Color := clBtnFace;
  end
  else if (Key <> '') and (aCol = 1) and not (gdSelected in aState) then
    FPropGrid.Canvas.Font.Color := clNavy;     // editable
end;

procedure TfrmReader.SetSeriesVisible(S: Integer; AVisible: Boolean);
begin
  FSeries[S].Visible := AVisible;
  FLine[S].Visible := AVisible;
  if S < FMnuSeries.Count then FMnuSeries.Items[S].Checked := AVisible;
  if FLineVisChk[S] <> nil then
  begin
    FUpdatingLines := True;
    FLineVisChk[S].Checked := AVisible;
    FUpdatingLines := False;
  end;
end;

{ apply an edited value; invalid input keeps the old value }
procedure TfrmReader.PropValidate(Sender: TObject; aCol, aRow: Integer;
  const OldValue: string; var NewValue: string);
var
  Key, V: string;
  T: TDateTime;
  D: Double;
  S: Integer;
  Ok, B: Boolean;

  function ParseBool(const X: string; out Res: Boolean): Boolean;
  begin
    Result := True;
    if SameText(X, 'yes') or SameText(X, 'true') or (X = '1') or SameText(X, 'on') then Res := True
    else if SameText(X, 'no') or SameText(X, 'false') or (X = '0') or SameText(X, 'off') then Res := False
    else Result := False;
  end;

  function ParseDT(const X: string; out Res: TDateTime): Boolean;
  begin
    Result := True;
    try
      Res := ScanDateTime('dd/mm/yyyy hh:nn:ss', Trim(X));
    except
      Result := False;
    end;
  end;

begin
  if aRow >= FPropKeys.Count then Exit;
  Key := FPropKeys[aRow];
  V := Trim(NewValue);
  Ok := False;
  if Key = 'from' then
  begin
    if ParseDT(V, T) and (T < FViewEnd) then
    begin
      FViewSpan := FViewEnd - T;
      SetView(FViewEnd);
      SyncWindowCombo;
      Ok := True;
    end;
  end
  else if Key = 'to' then
  begin
    if ParseDT(V, T) and (T > ViewStart) then
    begin
      FViewSpan := T - ViewStart;
      SetView(T);
      SyncWindowCombo;
      Ok := True;
    end;
  end
  else if Key = 'span' then
  begin
    if TryStrToFloat(V, D, FS) and (D > 0) then
    begin
      SetSpan(D * OneSecond);
      Ok := True;
    end;
  end
  else if Key = 'grid' then
  begin
    if ParseBool(V, B) then
    begin
      FShowGrid := B;
      FMnuGridLines.Checked := B;
      Ok := True;
    end;
  end
  else if Key = 'gap' then
  begin
    if TryStrToFloat(V, D, FS) and (D > 0) then
    begin
      FGapSeconds := D;
      BuildGaps;
      Ok := True;
    end;
  end
  else if Copy(Key, 1, 3) = 'vis' then
  begin
    S := StrToIntDef(Copy(Key, 4, 9), -1);
    if (S >= 0) and (S < FSeriesCount) and ParseBool(V, B) then
    begin
      SetSeriesVisible(S, B);
      Ok := True;
    end;
  end
  else if (Copy(Key, 1, 4) = 'ymin') or (Copy(Key, 1, 4) = 'ymax') then
  begin
    S := StrToIntDef(Copy(Key, 5, 9), -1);
    if (S >= 0) and (S < FSeriesCount) and TryStrToFloat(V, D, FS) then
    begin
      if Copy(Key, 1, 4) = 'ymin' then
        Ok := D < FSeries[S].AxisMax
      else
        Ok := D > FSeries[S].AxisMin;
      if Ok then
      begin
        if Copy(Key, 1, 4) = 'ymin' then FSeries[S].AxisMin := D
        else FSeries[S].AxisMax := D;
        FSeries[S].AxisUser := True;
      end;
    end;
  end;
  if not Ok then
    NewValue := OldValue
  else
    FPaintBox.Invalidate;
end;

{ the wheel scrolls the list (3 rows per notch) }
procedure TfrmReader.PropGridWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
begin
  FPropGrid.TopRow := EnsureRange(FPropGrid.TopRow - Sign(WheelDelta) * 3, FPropGrid.FixedRows,
    Max(FPropGrid.FixedRows, FPropGrid.RowCount - FPropGrid.VisibleRowCount));
  Handled := True;
end;

procedure TfrmReader.BtnCopyPropsClick(Sender: TObject);
var
  SL: TStringList;
  r: Integer;
begin
  RefreshChartPanel;
  SL := TStringList.Create;
  try
    for r := 1 to FPropGrid.RowCount - 1 do
      if (r < FPropKeys.Count) and (FPropKeys[r] = '#') then
        SL.Add(LineEnding + '[' + FPropGrid.Cells[0, r] + ']')
      else
        SL.Add(FPropGrid.Cells[0, r] + ': ' + FPropGrid.Cells[1, r]);
    Clipboard.AsText := Trim(SL.Text);
    FLblStatus.Caption := 'Chart information copied to the clipboard';
  finally
    SL.Free;
  end;
end;

{ ---------- pin data ---------- }

procedure TfrmReader.BuildPinPanel;
const
  SpinX: array[0..5] of Integer = (160, 208, 256, 326, 374, 422);
  SpinW: array[0..5] of Integer = (46, 46, 62, 46, 46, 46);
  MinV: array[0..5] of Integer = (1, 1, 2000, 0, 0, 0);
  MaxV: array[0..5] of Integer = (31, 12, 2100, 23, 59, 59);
  Captions: array[0..5] of string = ('Day', 'Month', 'Year', 'Hour', 'Minute', 'Second');
var
  Bar: TPanel;
  Lbl: TLabel;
  Btn: TButton;
  i: Integer;

  function AddButton(ALeft, AWidth: Integer; const ACaption, AHint: string;
    AHandler: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Bar;
    Result.SetBounds(ALeft, 4, AWidth, 26);
    Result.Caption := ACaption;
    Result.Hint := AHint;
    Result.ShowHint := True;
    Result.OnClick := AHandler;
  end;

begin
  FPinPanel := TPanel.Create(Self);
  FPinPanel.Parent := Self;
  FPinPanel.Align := alBottom;
  FPinPanel.Height := 150;
  FPinPanel.BevelOuter := bvNone;

  Bar := TPanel.Create(Self);
  Bar.Parent := FPinPanel;
  Bar.Align := alTop;
  Bar.Height := 34;
  Bar.BevelOuter := bvNone;

  Lbl := TLabel.Create(Self);
  Lbl.Parent := Bar;
  Lbl.SetBounds(8, 9, 150, 18);
  Lbl.Caption := 'Pin time (D/M/Y  h:m:s)';
  Lbl.Font.Style := [fsBold];

  for i := 0 to 5 do
  begin
    FPinSpins[i] := TSpinEdit.Create(Self);
    FPinSpins[i].Parent := Bar;
    FPinSpins[i].SetBounds(SpinX[i], 5, SpinW[i], 24);
    FPinSpins[i].MinValue := MinV[i];
    FPinSpins[i].MaxValue := MaxV[i];
    FPinSpins[i].Hint := Captions[i];
    FPinSpins[i].ShowHint := True;
  end;

  AddButton(476, 76, 'Add pin', 'Pin the time entered on the left', @BtnAddPinClick);
  AddButton(556, 60, 'Go to', 'Show the selected pin in the middle of the chart',
    @BtnGoToPinClick);
  AddButton(620, 70, 'Remove', 'Remove the selected pin (Delete key)', @BtnRemovePinClick);
  Btn := AddButton(694, 70, 'Clear all', 'Remove all pins', @BtnClearPinsClick);

  Lbl := TLabel.Create(Self);
  Lbl.Parent := Bar;
  Lbl.SetBounds(Btn.Left + Btn.Width + 12, 9, 420, 18);
  Lbl.Caption := 'Click on the chart to pin that moment - double-click a row to go there';
  Lbl.Font.Color := clGrayText;

  FPinGrid := TStringGrid.Create(Self);
  FPinGrid.Parent := FPinPanel;
  FPinGrid.Align := alClient;
  FPinGrid.FixedCols := 0;
  FPinGrid.RowCount := 1;
  FPinGrid.FixedRows := 1;
  FPinGrid.ColCount := 2;
  FPinGrid.Options := FPinGrid.Options + [goRowSelect, goColSizing] - [goRangeSelect];
  FPinGrid.DefaultRowHeight := 22;
  FPinGrid.OnDblClick := @PinGridDblClick;
  FPinGrid.OnKeyDown := @PinGridKeyDown;
  FPinGrid.OnSelection := @PinGridSelection;

  for i := 0 to 5 do
    FPinSpins[i].Value := MinV[i];
  RefreshPinGrid;
end;

{ sample index of pin P, -1 when that time is not in the data }
function TfrmReader.PinIndex(P: Integer): Integer;
begin
  Result := NearestIndex(FPins[P]);
  if (Result >= 0) and (Abs(FTimes[Result] - FPins[P]) * SecsPerDay > 1) then
    Result := -1;
end;

function TfrmReader.SelectedPin: Integer;
begin
  Result := -1;
  if (FPinGrid <> nil) and (FPinGrid.Row >= 1) and (FPinGrid.Row <= Length(FPins)) then
    Result := FPinGrid.Row - 1;
end;

{ pins the sample nearest to T; pins stay sorted by time (P1 = oldest) }
procedure TfrmReader.AddPin(T: TDateTime; FromChart: Boolean);
var
  Idx, P, i: Integer;
  Y, Mo, D, H, Mi, S, MS: Word;
begin
  if FCount = 0 then Exit;
  if not FromChart and ((T < FTimes[0] - OneSecond) or (T > FTimes[FCount - 1] + OneSecond)) then
  begin
    MessageDlg('There is no data at ' + FormatDateTime('dd/mm/yyyy hh:nn:ss', T) + '.' +
      LineEnding + 'Data range: ' + FormatDateTime('dd/mm/yyyy hh:nn:ss', FTimes[0]) +
      ' - ' + FormatDateTime('dd/mm/yyyy hh:nn:ss', FTimes[FCount - 1]),
      mtInformation, [mbOK], 0);
    Exit;
  end;
  Idx := NearestIndex(T);
  T := FTimes[Idx];

  for P := 0 to High(FPins) do
    if PinIndex(P) = Idx then
    begin
      // already pinned -> select it
      FPinGrid.Row := P + 1;
      FPaintBox.Invalidate;
      Exit;
    end;

  P := 0;
  while (P <= High(FPins)) and (FPins[P] < T) do Inc(P);
  SetLength(FPins, Length(FPins) + 1);
  for i := High(FPins) downto P + 1 do
    FPins[i] := FPins[i - 1];
  FPins[P] := T;

  DecodeDateTime(T, Y, Mo, D, H, Mi, S, MS);
  FPinSpins[0].Value := D;
  FPinSpins[1].Value := Mo;
  FPinSpins[2].Value := Y;
  FPinSpins[3].Value := H;
  FPinSpins[4].Value := Mi;
  FPinSpins[5].Value := S;
  RefreshPinGrid;
  FPinGrid.Row := P + 1;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.RemovePin(P: Integer);
var
  i: Integer;
begin
  if (P < 0) or (P > High(FPins)) then Exit;
  for i := P to High(FPins) - 1 do
    FPins[i] := FPins[i + 1];
  SetLength(FPins, Length(FPins) - 1);
  RefreshPinGrid;
  if Length(FPins) > 0 then
    FPinGrid.Row := Min(P, High(FPins)) + 1;
  FPaintBox.Invalidate;
end;

{ one row per pin: number, time, value of each data set }
procedure TfrmReader.RefreshPinGrid;
var
  P, s, Idx: Integer;
begin
  if FPinGrid = nil then Exit;
  FPinGrid.BeginUpdate;
  try
    FPinGrid.ColCount := 2 + FSeriesCount;
    FPinGrid.ColWidths[0] := 50;
    FPinGrid.ColWidths[1] := 180;
    FPinGrid.Cells[0, 0] := 'Pin';
    FPinGrid.Cells[1, 0] := 'Time';
    for s := 0 to FSeriesCount - 1 do
    begin
      FPinGrid.Cells[2 + s, 0] := FSeries[s].Name + ' [' + KindNames[FSeries[s].Kind] + ']';
      FPinGrid.ColWidths[2 + s] := 170;
    end;
    FPinGrid.RowCount := 1 + Length(FPins);
    for P := 0 to High(FPins) do
    begin
      Idx := PinIndex(P);
      FPinGrid.Cells[0, P + 1] := 'P' + IntToStr(P + 1);
      FPinGrid.Cells[1, P + 1] := FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FPins[P]);
      for s := 0 to FSeriesCount - 1 do
        if Idx >= 0 then
          FPinGrid.Cells[2 + s, P + 1] := DisplayValue(s, FData[s][Idx])
        else
          FPinGrid.Cells[2 + s, P + 1] := '- (no data)';
    end;
  finally
    FPinGrid.EndUpdate;
  end;
end;

procedure TfrmReader.GoToPin(P: Integer);
var
  Idx: Integer;
begin
  if (P < 0) or (P > High(FPins)) then Exit;
  Idx := PinIndex(P);
  if Idx < 0 then Exit;
  SetView(FTimes[Idx] + FViewSpan / 2);
end;

procedure TfrmReader.BtnAddPinClick(Sender: TObject);
var
  T: TDateTime;
begin
  if not TryEncodeDateTime(FPinSpins[2].Value, FPinSpins[1].Value, FPinSpins[0].Value,
    FPinSpins[3].Value, FPinSpins[4].Value, FPinSpins[5].Value, 0, T) then
  begin
    MessageDlg('The pin time is not a valid date / time.', mtError, [mbOK], 0);
    Exit;
  end;
  AddPin(T, False);
  GoToPin(SelectedPin);
end;

procedure TfrmReader.BtnGoToPinClick(Sender: TObject);
begin
  GoToPin(SelectedPin);
end;

procedure TfrmReader.BtnRemovePinClick(Sender: TObject);
begin
  RemovePin(SelectedPin);
end;

procedure TfrmReader.BtnClearPinsClick(Sender: TObject);
begin
  SetLength(FPins, 0);
  RefreshPinGrid;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.PinGridDblClick(Sender: TObject);
begin
  GoToPin(SelectedPin);
end;

procedure TfrmReader.PinGridKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_DELETE then
  begin
    RemovePin(SelectedPin);
    Key := 0;
  end
  else if Key = VK_RETURN then
  begin
    GoToPin(SelectedPin);
    Key := 0;
  end;
end;

procedure TfrmReader.PinGridSelection(Sender: TObject; aCol, aRow: Integer);
begin
  FPaintBox.Invalidate;    // the selected pin is drawn thicker
end;

procedure TfrmReader.MnuPinsClick(Sender: TObject);
begin
  FMnuPins.Checked := not FMnuPins.Checked;
  FPinPanel.Visible := FMnuPins.Checked;
  FPinSplitter.Visible := FMnuPins.Checked;
  if FPinSplitter.Visible then
  begin
    FPinPanel.Top := ClientHeight;
    FPinSplitter.Top := FPinPanel.Top - 1;
  end;
end;

{ ---------- zoom box ---------- }

procedure TfrmReader.PushZoom;
var
  Z: TZoomState;
  s: Integer;
begin
  Z.ViewEnd := FViewEnd;
  Z.ViewSpan := FViewSpan;
  for s := 0 to MaxSeries - 1 do
    Z.Series[s] := FSeries[s];
  SetLength(FZoomStack, Length(FZoomStack) + 1);
  FZoomStack[High(FZoomStack)] := Z;
end;

procedure TfrmReader.UndoZoom;
var
  Z: TZoomState;
  s: Integer;
begin
  if Length(FZoomStack) = 0 then
  begin
    MnuShowAllClick(nil);
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
  SetView(Z.ViewEnd);
  SyncWindowCombo;
end;

procedure TfrmReader.ZoomToRect(const Sel: TRect);
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
    SetView((T1 + T2) / 2 + FViewSpan / 2);
    SyncWindowCombo;
  end
  else
    FPaintBox.Invalidate;
  UpdateStatus;
end;

function TfrmReader.VisibleAxisCount: Integer;
var
  s: Integer;
begin
  Result := 0;
  for s := 0 to FSeriesCount - 1 do
    if FSeries[s].Visible then Inc(Result);
end;

function TfrmReader.AxisLeft(S: Integer): Integer;
var
  i, n: Integer;
begin
  if not FSeries[S].Visible then Exit(-1);
  n := 0;
  for i := 0 to S - 1 do
    if FSeries[i].Visible then Inc(n);
  Result := 4 + n * AxisWidth;
end;

function TfrmReader.AxisAt(X, Y: Integer): Integer;
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

function TfrmReader.PlotRect: TRect;
begin
  Result := Rect(8 + Max(1, VisibleAxisCount) * AxisWidth, 52,
    FPaintBox.Width - 16, FPaintBox.Height - XAxisHeight - 4);
end;

function TfrmReader.DisplayValue(S: Integer; V: Double): string;
begin
  if IsNan(V) then Exit('-');
  case FSeries[S].Kind of
    dkBoolean: if V >= 0.5 then Result := 'True' else Result := 'False';
    dkByte, dkInteger: Result := IntToStr(Round(V));
  else
    Result := FormatFloat('0.00', V);
  end;
end;

{ ---------- drawing ---------- }

procedure TfrmReader.DrawChart(P: TChartPainter; W, H: Integer; Interactive: Boolean);
const
  PinColor: TBGRAPixel = (blue: 90; green: 220; red: 255; alpha: 255);
var
  R: TRect;
  PW, PH, s, i, i0, i1, Step, AxL, AxX, NTicks, Idx, px, CurPx, BCount, Day, pn: Integer;
  TStart, Span, SpanSec, T0Sec, TSec, YStep, V, BMin, BMax, BFirst, BLast: Double;
  X, Yf, LegendX, BX, TW: Single;
  Pts, MPts: array of TPointF;
  NPts, NM, VisCount: Integer;
  DrawMarkers: Boolean;
  ColLo, ColHi: array of Double;
  LC: TBGRAPixel;
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

  procedure AddMark(AX, AY: Single);
  begin
    if NM >= Length(MPts) then SetLength(MPts, NM * 2 + 256);
    MPts[NM] := PointF(AX, AY);
    Inc(NM);
  end;

  { marker of the given kind, centred on X, Y }
  procedure DrawMarker(AX, AY: Single; Kind: TMarkerKind; Size: Single; AColor: TBGRAPixel);
  var
    H: Single;
  begin
    H := Size / 2;
    case Kind of
      mkCircle: P.Circle(AX, AY, H, AColor, BGRAPixelTransparent, 0);
      mkSquare: P.FillRect(AX - H, AY - H, AX + H, AY + H, AColor);
      mkCross:
        begin
          P.Line(AX - H, AY - H, AX + H, AY + H, AColor, Max(1.2, Size / 5));
          P.Line(AX - H, AY + H, AX + H, AY - H, AColor, Max(1.2, Size / 5));
        end;
      mkPlus:
        begin
          P.Line(AX - H, AY, AX + H, AY, AColor, Max(1.2, Size / 5));
          P.Line(AX, AY - H, AX, AY + H, AColor, Max(1.2, Size / 5));
        end;
    end;
  end;

  procedure FlushSegment(S: Integer);
  begin
    if Interactive then Inc(FDrawn[S], NPts);
    if FLine[S].Mode <> lmPoints then
    begin
      if NPts >= 2 then
        P.Polyline(Copy(Pts, 0, NPts), LC, FLine[S].Width, FLine[S].Style)
      else if NPts = 1 then
        P.Circle(Pts[0].X, Pts[0].Y, Max(1.5, FLine[S].Width), LC, BGRAPixelTransparent, 0);
    end;
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
      // steps: the value holds until the next sample
      if ((FSeries[S].Kind = dkBoolean) or (FLine[S].Mode = lmSteps)) and (NPts > 0) and
         (Pts[NPts - 1].Y <> Yf) then
        AddPt(BX, Pts[NPts - 1].Y);
      AddPt(BX, Yf);
      if DrawMarkers then AddMark(BX, Yf);
    end
    else
    begin
      PX0 := R.Left + CurPx + 0.5;
      AddPt(PX0, YOf(S, BFirst));
      AddPt(PX0, YOf(S, BMin));
      AddPt(PX0, YOf(S, BMax));
      AddPt(PX0, YOf(S, BLast));
      if DrawMarkers then
      begin
        AddMark(PX0, YOf(S, BMin));
        AddMark(PX0, YOf(S, BMax));
      end;
    end;
    BCount := 0;
  end;

  { column rendering for dense data: every pixel column gets one vertical
    span = min..max of its samples (LOD pyramid) joined with the line from
    the previous column; no antialiasing, one FillRect per column }
  procedure DrawDense(S: Integer);
  var
    j, k, c, c0, c1, ra, rb, a, b, a0, b0, ia, ib, gi, wpx, Filled, iv0, iv1: Integer;
    TA, TB, Mn, Mx, XPrev, YPrev, XC, YFirst, Half, Lo, Hi: Double;
    PrevOk, StepMode, PointMode: Boolean;

    function RelX(T: TDateTime): Double;
    begin
      Result := (T - TStart) / Span * PW;
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
      // keep far away points out of the integer range (same slope)
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
    StepMode := (FLine[S].Mode = lmSteps) or (FSeries[S].Kind = dkBoolean);
    PointMode := FLine[S].Mode = lmPoints;
    for j := 0 to PW - 1 do
    begin
      ColLo[j] := 1e30;
      ColHi[j] := -1e30;
    end;
    iv0 := LowerBound(TStart);
    iv1 := LowerBound(FViewEnd + OneMillisecond) - 1;

    // runs of samples between gaps
    ra := i0;
    gi := GapIndexFrom(i0 + 1);
    while ra <= i1 do
    begin
      if (gi <= High(FGapIdx)) and (FGapIdx[gi] <= i1) then
        rb := FGapIdx[gi] - 1
      else
        rb := i1;
      PrevOk := False;
      // start at the last sample before the view
      if ra < iv0 then
      begin
        k := Min(iv0 - 1, rb);
        while (k >= ra) and IsNan(FData[S][k]) do Dec(k);
        if k >= ra then
        begin
          XPrev := RelX(FTimes[k]);
          YPrev := YOf(S, FData[S][k]);
          PrevOk := True;
        end;
      end;
      a0 := Max(ra, iv0);
      b0 := Min(rb, iv1);
      if a0 <= b0 then
      begin
        c0 := Max(0, Floor(RelX(FTimes[a0])));
        c1 := Min(PW - 1, Floor(RelX(FTimes[b0])));
        for c := c0 to c1 do
        begin
          TA := TStart + c * Span / PW;
          TB := TA + Span / PW;
          a := Max(a0, LowerBound(TA));
          b := Min(b0, LowerBound(TB) - 1);
          if a > b then Continue;
          if not RangeMinMax(S, a, b, Mn, Mx) then
          begin
            PrevOk := False;          // only missing values: break the line
            Continue;
          end;
          ia := a;
          while IsNan(FData[S][ia]) do Inc(ia);
          ib := b;
          while IsNan(FData[S][ib]) do Dec(ib);
          YFirst := YOf(S, FData[S][ia]);
          XC := RelX(FTimes[ia]);
          if PrevOk and not PointMode then Connect(XC, YFirst);
          AddSpan(c, YOf(S, Mx), YOf(S, Mn));
          XPrev := RelX(FTimes[ib]);
          YPrev := YOf(S, FData[S][ib]);
          PrevOk := True;
        end;
      end;
      // on to the first sample after the view
      if PrevOk and not PointMode and (rb > iv1) then
      begin
        k := Max(iv1 + 1, ra);
        while (k <= rb) and IsNan(FData[S][k]) do Inc(k);
        if k <= rb then Connect(RelX(FTimes[k]), YOf(S, FData[S][k]));
      end;
      ra := rb + 1;
      Inc(gi);
    end;

    // one rectangle per column; line width = horizontal + vertical dilation
    wpx := Max(1, Round(FLine[S].Width));
    Half := Max(0, (FLine[S].Width - 1) / 2);
    Filled := 0;
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
      P.FillRect(R.Left + j, Floor(Lo - Half), R.Left + j + 1, Floor(Hi + Half) + 1, LC);
      Inc(Filled);
    end;
    if Interactive then Inc(FDrawn[S], Filled);
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
    P.Text((R.Left + R.Right) / 2, (R.Top + R.Bottom) / 2 - 8,
      'File > Open (or drop CSV files here) - main data file, daily files or data set exports',
      BGRA(170, 170, 180), taCenter);
    Exit;
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
    if Interactive and (s = FAxisDrag) then
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
  if Interactive then
  begin
    FLastTimeStep := Step;
    for i := 0 to MaxSeries - 1 do FDrawn[i] := 0;
  end;
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
  i0 := Max(0, LowerBound(TStart) - 1);
  i1 := Min(FCount - 1, LowerBound(FViewEnd));
  P.Clip(R);
  VisCount := i1 - i0 + 1;
  SetLength(ColLo, PW);
  SetLength(ColHi, PW);
  for s := 0 to FSeriesCount - 1 do
  begin
    if not FSeries[s].Visible then Continue;
    LC := LineColor(s);
    // dense: column rendering, sparse: antialiased polyline (+ markers)
    FDense[s] := VisCount > PW div 2;
    if FDense[s] then
    begin
      DrawDense(s);
      Continue;
    end;
    // markers: always for "Points", otherwise only when they do not overlap
    DrawMarkers := (FLine[s].Mode = lmPoints) or
      ((FLine[s].Marker <> mkNone) and (VisCount <= PW / Max(2, FLine[s].MarkerSize * 1.5)));
    NPts := 0;
    NM := 0;
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
      if (i > i0) and ((FTimes[i] - FTimes[i - 1]) * SecsPerDay > FGapSeconds) then
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
    if DrawMarkers then
      for i := 0 to NM - 1 do
        if FLine[s].Marker = mkNone then
          DrawMarker(MPts[i].X, MPts[i].Y, mkCircle, Max(2.5, FLine[s].Width * 2), LC)
        else
          DrawMarker(MPts[i].X, MPts[i].Y, FLine[s].Marker, FLine[s].MarkerSize, LC);
  end;
  // pinned times: dashed line, label, value of every set
  for pn := 0 to High(FPins) do
  begin
    Idx := PinIndex(pn);
    if (Idx < 0) or (FTimes[Idx] < TStart) or (FTimes[Idx] > FViewEnd) then Continue;
    X := XOf(FTimes[Idx]);
    if Interactive and (pn = SelectedPin) then TW := 2.2 else TW := 1.2;
    P.Line(X, R.Top, X, R.Bottom, PinColor, TW, psDash);
    Txt := 'P' + IntToStr(pn + 1);
    TW := P.TextWidth(Txt);
    P.RoundRect(X - TW / 2 - 4, R.Top + 2, X + TW / 2 + 4, R.Top + 19, 4, PinColor);
    P.Text(X, R.Top + 3, Txt, BGRA(20, 20, 20), taCenter);
    for s := 0 to FSeriesCount - 1 do
      if FSeries[s].Visible and not IsNan(FData[s][Idx]) then
      begin
        Yf := YOf(s, FData[s][Idx]);
        P.Circle(X, Yf, 4.2, FSeries[s].Color, PinColor, 1.2);
        P.Text(X + 7, Yf - 17, DisplayValue(s, FData[s][Idx]), FSeries[s].Color);
      end;
  end;
  P.NoClip;

  // the export shows the time range; on screen the overlay draws the
  // hover readout / hint in that place
  if not Interactive then
    P.Text(R.Left, 28, FormatDateTime('dd/mm/yyyy hh:nn:ss', TStart) + '  -  ' +
      FormatDateTime('dd/mm/yyyy hh:nn:ss', FViewEnd), BGRA(170, 174, 182));

  // legend
  LegendX := R.Left;
  for s := 0 to FSeriesCount - 1 do
  begin
    if FSeries[s].Visible then C := LineColor(s) else C := BGRA(90, 90, 95);
    if FLine[s].Mode <> lmPoints then
      P.Line(LegendX, 15, LegendX + 22, 15, C, Max(1.5, FLine[s].Width), FLine[s].Style);
    if FLine[s].Mode = lmPoints then
      DrawMarker(LegendX + 11, 15, TMarkerKind(IfThen(FLine[s].Marker = mkNone, Ord(mkCircle),
        Ord(FLine[s].Marker))), Max(4, Min(10, FLine[s].MarkerSize)), C)
    else if FLine[s].Marker <> mkNone then
      DrawMarker(LegendX + 11, 15, FLine[s].Marker, Max(4, Min(10, FLine[s].MarkerSize)), C);
    Txt := Format('Y%d: %s [%s]', [s + 1, FSeries[s].Name, KindNames[FSeries[s].Kind]]);
    P.Text(LegendX + 28, 7, Txt, BGRA(220, 220, 225));
    LegendX := LegendX + 28 + P.TextWidth(Txt) + 28;
  end;

  P.Frame(R.Left, R.Top, R.Right, R.Bottom, BGRA(90, 95, 105));
end;

{ everything the cached chart depends on; a different signature means the
  cache has to be rendered again (no change missed, nothing to invalidate) }
function TfrmReader.ChartSignature(W, H: Integer): string;
var
  i: Integer;
  PinSum: Double;
begin
  PinSum := 0;
  for i := 0 to High(FPins) do PinSum := PinSum + FPins[i];
  Result := Format('%d|%d|%d|%d|%.12g|%.12g|%d|%d|%d|%.6g|%d|%.12g|%d',
    [W, H, FCount, FDataVersion, FViewEnd, FViewSpan, Ord(FShowGrid), FAxisDrag,
     SelectedPin, FGapSeconds, Length(FPins), PinSum, FSeriesCount]);
  for i := 0 to FSeriesCount - 1 do
    with FSeries[i], FLine[i] do
      Result := Result + Format('|%.9g|%.9g|%d|%d|%d|%d|%d|%.3g|%d|%d|%.3g',
        [AxisMin, AxisMax, Ord(Visible), LongInt(Color), Opacity, Ord(Style), Ord(Mode),
         Width, Ord(Marker), Ord(Kind), MarkerSize]);
end;

{ the complete interactive chart into Dest (size of the paint box):
  the cached chart (rendered again only when something changed) plus the
  mouse overlay }
procedure TfrmReader.RenderFrame(Dest: TBGRABitmap);
var
  P: TBGRAChartPainter;
  Sig: string;
begin
  Sig := ChartSignature(Dest.Width, Dest.Height);
  if (FCache = nil) or (FCache.Width <> Dest.Width) or (FCache.Height <> Dest.Height) or
     (Sig <> FCacheSig) then
  begin
    if FCache = nil then
      FCache := TBGRABitmap.Create(Dest.Width, Dest.Height, BackColor)
    else if (FCache.Width <> Dest.Width) or (FCache.Height <> Dest.Height) then
      FCache.SetSize(Dest.Width, Dest.Height);
    P := TBGRAChartPainter.Create(FCache);
    try
      DrawChart(P, FCache.Width, FCache.Height, True);
    finally
      P.Free;
    end;
    FCacheSig := Sig;
    Inc(FCacheMisses);
  end
  else
    Inc(FCacheHits);
  Dest.PutImage(0, 0, FCache, dmSet);
  P := TBGRAChartPainter.Create(Dest);
  try
    DrawOverlay(P);
  finally
    P.Free;
  end;
end;

{ mouse layer: crosshair + readout (or the hint) and the zoom box }
procedure TfrmReader.DrawOverlay(P: TChartPainter);
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
  if (PW < 20) or (PH < 20) or (FCount = 0) or (FSeriesCount = 0) then Exit;
  TStart := ViewStart;
  Span := FViewSpan;
  SpanSec := Span * SecsPerDay;

  if (FHoverX >= R.Left) and (FHoverX < R.Right) and (FHoverY >= R.Top) and
     (FHoverY <= R.Bottom) and not FDragging and not FSelecting and (FAxisDrag < 0) then
  begin
    T := TStart + (FHoverX - R.Left) / PW * Span;
    Idx := NearestIndex(T);
    if (Idx >= 0) and (Abs(FTimes[Idx] - T) * SecsPerDay <= Max(FGapSeconds, SpanSec / PW * 2)) then
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
    P.Text(R.Left, 28, 'Click = pin, drag box = zoom (right-to-left = undo), wheel = zoom time, ' +
      'right-drag / drag X axis = scroll, drag Y axis = move', BGRA(120, 124, 132));

  if FSelecting and ((Abs(FSelEnd.X - FSelStart.X) > 2) or (Abs(FSelEnd.Y - FSelStart.Y) > 2)) then
  begin
    if FSelEnd.X < FSelStart.X - 5 then C := BGRA(255, 120, 120)
    else C := BGRA(120, 180, 255);
    P.FillRect(Min(FSelStart.X, FSelEnd.X), Min(FSelStart.Y, FSelEnd.Y),
      Max(FSelStart.X, FSelEnd.X), Max(FSelStart.Y, FSelEnd.Y), BGRA(C.red, C.green, C.blue, 40));
    P.Frame(Min(FSelStart.X, FSelEnd.X), Min(FSelStart.Y, FSelEnd.Y),
      Max(FSelStart.X, FSelEnd.X), Max(FSelStart.Y, FSelEnd.Y), C, 1.01);
    if FSelEnd.X < FSelStart.X - 5 then
      P.Text(Min(FSelStart.X, FSelEnd.X) + 4, Min(FSelStart.Y, FSelEnd.Y) + 2, 'Undo zoom', C);
  end;
end;

{ ---------- speed structures ---------- }

{ min / max pyramid (blocks of 16, 256, 4096 ... samples, NaN ignored)
  and prefix sums of value, value^2 and count; then the gap list }
procedure TfrmReader.BuildLOD;
var
  sr, i, k, n, nb, lv, Cnt: Integer;
  V, Sum, Sum2: Double;
begin
  n := FCount;
  SetLength(FLodSize, 0);
  k := 16;
  while k < n do
  begin
    SetLength(FLodSize, Length(FLodSize) + 1);
    FLodSize[High(FLodSize)] := k;
    if k > MaxInt div 16 then Break;
    k := k * 16;
  end;
  for sr := 0 to MaxSeries - 1 do
  begin
    SetLength(FLodMin[sr], 0);
    SetLength(FLodMax[sr], 0);
    SetLength(FPreSum[sr], 0);
    SetLength(FPreSum2[sr], 0);
    SetLength(FPreCnt[sr], 0);
  end;
  for sr := 0 to FSeriesCount - 1 do
  begin
    SetLength(FLodMin[sr], Length(FLodSize));
    SetLength(FLodMax[sr], Length(FLodSize));
    for lv := 0 to High(FLodSize) do
    begin
      nb := (n + FLodSize[lv] - 1) div FLodSize[lv];
      SetLength(FLodMin[sr][lv], nb);
      SetLength(FLodMax[sr][lv], nb);
      for i := 0 to nb - 1 do
      begin
        FLodMin[sr][lv][i] := Infinity;
        FLodMax[sr][lv][i] := NegInfinity;
      end;
      if lv = 0 then
      begin
        for i := 0 to n - 1 do
        begin
          V := FData[sr][i];
          if IsNan(V) then Continue;
          k := i shr 4;
          if V < FLodMin[sr][0][k] then FLodMin[sr][0][k] := V;
          if V > FLodMax[sr][0][k] then FLodMax[sr][0][k] := V;
        end;
      end
      else
        for i := 0 to High(FLodMin[sr][lv - 1]) do
        begin
          k := i shr 4;
          if FLodMin[sr][lv - 1][i] < FLodMin[sr][lv][k] then FLodMin[sr][lv][k] := FLodMin[sr][lv - 1][i];
          if FLodMax[sr][lv - 1][i] > FLodMax[sr][lv][k] then FLodMax[sr][lv][k] := FLodMax[sr][lv - 1][i];
        end;
    end;
    SetLength(FPreSum[sr], n + 1);
    SetLength(FPreSum2[sr], n + 1);
    SetLength(FPreCnt[sr], n + 1);
    Sum := 0;
    Sum2 := 0;
    Cnt := 0;
    FPreSum[sr][0] := 0;
    FPreSum2[sr][0] := 0;
    FPreCnt[sr][0] := 0;
    for i := 0 to n - 1 do
    begin
      V := FData[sr][i];
      if not IsNan(V) then
      begin
        Sum := Sum + V;
        Sum2 := Sum2 + V * V;
        Inc(Cnt);
      end;
      FPreSum[sr][i + 1] := Sum;
      FPreSum2[sr][i + 1] := Sum2;
      FPreCnt[sr][i + 1] := Cnt;
    end;
  end;
  BuildGaps;
end;

procedure TfrmReader.BuildGaps;
var
  i, n: Integer;
begin
  SetLength(FGapIdx, 0);
  n := 0;
  for i := 1 to FCount - 1 do
    if (FTimes[i] - FTimes[i - 1]) * SecsPerDay > FGapSeconds then
    begin
      if n >= Length(FGapIdx) then SetLength(FGapIdx, n * 2 + 16);
      FGapIdx[n] := i;
      Inc(n);
    end;
  SetLength(FGapIdx, n);
end;

{ min / max of samples A..B: whole pyramid blocks where they fit, single
  samples at the ragged ends - O(16 x levels) instead of O(B - A) }
function TfrmReader.RangeMinMax(S, A, B: Integer; out Mn, Mx: Double): Boolean;
var
  i, lv, sz, TopLv: Integer;
  V: Double;
  Used: Boolean;
begin
  Mn := Infinity;
  Mx := NegInfinity;
  TopLv := Min(High(FLodSize), High(FLodMin[S]));
  i := Max(0, A);
  B := Min(B, FCount - 1);
  while i <= B do
  begin
    Used := False;
    for lv := TopLv downto 0 do
    begin
      sz := FLodSize[lv];
      if (i mod sz = 0) and (i + sz - 1 <= B) then
      begin
        V := FLodMin[S][lv][i div sz];
        if V < Mn then Mn := V;
        V := FLodMax[S][lv][i div sz];
        if V > Mx then Mx := V;
        Inc(i, sz);
        Used := True;
        Break;
      end;
    end;
    if not Used then
    begin
      V := FData[S][i];
      if not IsNan(V) then
      begin
        if V < Mn then Mn := V;
        if V > Mx then Mx := V;
      end;
      Inc(i);
    end;
  end;
  Result := Mn <= Mx;
end;

{ sum, sum of squares and count of the valid samples A..B in O(1) }
procedure TfrmReader.RangeSums(S, A, B: Integer; out Sum, Sum2: Double; out Cnt: Integer);
begin
  Sum := 0;
  Sum2 := 0;
  Cnt := 0;
  A := Max(0, A);
  B := Min(B, FCount - 1);
  if (B < A) or (Length(FPreCnt[S]) <= B + 1) then Exit;
  Sum := FPreSum[S][B + 1] - FPreSum[S][A];
  Sum2 := FPreSum2[S][B + 1] - FPreSum2[S][A];
  Cnt := FPreCnt[S][B + 1] - FPreCnt[S][A];
end;

{ first position in the gap list with a sample index >= I }
function TfrmReader.GapIndexFrom(I: Integer): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  Lo := 0;
  Hi := Length(FGapIdx);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if FGapIdx[Mid] < I then Lo := Mid + 1 else Hi := Mid;
  end;
  Result := Lo;
end;

{ gaps between samples A..B }
function TfrmReader.GapsBetween(A, B: Integer): Integer;
begin
  if B <= A then Exit(0);
  Result := GapIndexFrom(B + 1) - GapIndexFrom(A + 1);
end;

function TfrmReader.LodBytes: Int64;
var
  sr, lv: Integer;
begin
  Result := Int64(Length(FGapIdx)) * SizeOf(Integer);
  for sr := 0 to MaxSeries - 1 do
  begin
    for lv := 0 to High(FLodMin[sr]) do
      Inc(Result, Int64(Length(FLodMin[sr][lv]) + Length(FLodMax[sr][lv])) * SizeOf(Double));
    Inc(Result, Int64(Length(FPreSum[sr]) + Length(FPreSum2[sr])) * SizeOf(Double) +
      Int64(Length(FPreCnt[sr])) * SizeOf(Integer));
  end;
end;

{ off-screen timing: full redraws (view changes) and hover-only frames,
  for the whole data and a 10 minute window; result in bench.txt }
procedure TfrmReader.RunBench(Data: PtrInt);
var
  SL: TStringList;
  Bmp: TBGRABitmap;
  N, Vis: Integer;
  Full, Hover: Double;

  { milliseconds since T (performance counter) }
  function MsSince(T: Int64): Double;
  var
    Now64, Freq: Int64;
  begin
    QueryPerformanceCounter(Now64);
    QueryPerformanceFrequency(Freq);
    Result := (Now64 - T) * 1000 / Freq;
  end;

  procedure Measure(const ACaption: string);
  var
    R: TRect;
    k: Integer;
    TC: Int64;
  begin
    R := PlotRect;
    Vis := LowerBound(FViewEnd + OneMillisecond) - LowerBound(ViewStart);
    FHoverX := -1;
    RenderFrame(Bmp);                       // warm up
    N := 20;
    QueryPerformanceCounter(TC);
    for k := 1 to N do
    begin
      FCacheSig := '';                      // force a full render of the chart
      RenderFrame(Bmp);
    end;
    Full := MsSince(TC) / N;
    N := 100;
    FHoverY := (R.Top + R.Bottom) div 2;
    QueryPerformanceCounter(TC);
    for k := 1 to N do
    begin
      FHoverX := R.Left + (k * 17) mod Max(1, R.Width);   // only the mouse moves
      RenderFrame(Bmp);
    end;
    Hover := MsSince(TC) / N;
    FHoverX := -1;
    SL.Add(Format('%-22s visible %8d   full redraw %8.2f ms   hover %8.2f ms',
      [ACaption, Vis, Full, Hover]));
  end;

begin
  SL := TStringList.Create;
  try
    FPaintBox.Align := alNone;
    FPaintBox.SetBounds(0, 0, 1200, 600);
    Bmp := TBGRABitmap.Create(1200, 600, BackColor);
    try
      SL.Add(Format('HistoryReader bench  %s  samples %d  chart 1200 x 600',
        [{$ifopt R+}'DEBUG (range checks)'{$else}'RELEASE'{$endif}, FCount]));
      ShowAll;
      Measure('all data');
      FViewSpan := 600 * OneSecond;
      SetView(LastTime);
      Measure('10 min window');
    finally
      Bmp.Free;
    end;
    SL.SaveToFile(ExtractFilePath(ParamStr(0)) + 'bench.txt');
  finally
    SL.Free;
  end;
  Application.Terminate;
end;

procedure TfrmReader.PaintBoxPaint(Sender: TObject);
var
  T0, T1, Freq: Int64;
begin
  if (FPaintBox.Width < 200) or (FPaintBox.Height < 100) then Exit;
  QueryPerformanceCounter(T0);
  // the frame bitmap is reused between paints
  if FFrame = nil then
    FFrame := TBGRABitmap.Create(FPaintBox.Width, FPaintBox.Height, BackColor)
  else if (FFrame.Width <> FPaintBox.Width) or (FFrame.Height <> FPaintBox.Height) then
    FFrame.SetSize(FPaintBox.Width, FPaintBox.Height);
  RenderFrame(FFrame);
  FFrame.Draw(FPaintBox.Canvas, 0, 0, True);
  // statistics for the chart panel
  QueryPerformanceCounter(T1);
  QueryPerformanceFrequency(Freq);
  FLastPaintMs := (T1 - T0) * 1000 / Freq;
  FTotalPaintMs := FTotalPaintMs + FLastPaintMs;
  Inc(FPaintCount);
end;

{ ---------- mouse ---------- }

procedure TfrmReader.PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  A: Integer;
  R: TRect;
begin
  if FDragging or FSelecting or (FAxisDrag >= 0) or (FCount = 0) then Exit;
  R := PlotRect;
  A := AxisAt(X, Y);
  if (Button = mbLeft) and (A >= 0) then
  begin
    FAxisDrag := A;
    FAxisDragY := Y;
    FAxisDragMin := FSeries[A].AxisMin;
  end
  else if (Button = mbLeft) and R.Contains(Point(X, Y)) then
  begin
    FSelecting := True;
    FSelStart := Point(X, Y);
    FSelEnd := FSelStart;
    FPaintBox.Cursor := crCross;
  end
  else if ((Button = mbLeft) and (Y > R.Bottom)) or
          ((Button = mbRight) and R.Contains(Point(X, Y))) then
  begin
    FDragging := True;
    FDragX := X;
    FDragEnd := FViewEnd;
    FPaintBox.Cursor := crSizeWE;
  end;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.PaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
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

procedure TfrmReader.PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Sel: TRect;
begin
  if FSelecting and (Button = mbLeft) then
  begin
    FSelecting := False;
    Sel := Rect(Min(FSelStart.X, FSelEnd.X), Min(FSelStart.Y, FSelEnd.Y),
      Max(FSelStart.X, FSelEnd.X), Max(FSelStart.Y, FSelEnd.Y));
    if (Abs(FSelEnd.X - FSelStart.X) <= 3) and (Abs(FSelEnd.Y - FSelStart.Y) <= 3) then
    begin
      if PlotRect.Width > 0 then
        AddPin(ViewStart + (FSelStart.X - PlotRect.Left) / PlotRect.Width * FViewSpan, True);
    end
    else if FSelEnd.X < FSelStart.X - 5 then
      UndoZoom
    else
      ZoomToRect(Sel);
  end;
  FDragging := False;
  FAxisDrag := -1;
  FPaintBox.Cursor := crDefault;
  FPaintBox.Invalidate;
end;

{ the right button scrolls the chart - no popup menu }
procedure TfrmReader.PaintBoxContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
begin
  Handled := True;
end;

procedure TfrmReader.PaintBoxMouseLeave(Sender: TObject);
begin
  FHoverX := -1;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.PaintBoxDblClick(Sender: TObject);
var
  A: Integer;
begin
  A := AxisAt(FHoverX, FHoverY);
  if A < 0 then Exit;
  FSeries[A].AxisUser := False;
  AutoAxes;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  Pt: TPoint;
  A: Integer;
  R: TRect;
  V, F: Double;
begin
  if FInfoPanel.Visible then
  begin
    Pt := FInfoPanel.ScreenToClient(Mouse.CursorPos);
    if FInfoPanel.ClientRect.Contains(Pt) then
    begin
      FInfoPanel.VertScrollBar.Position := FInfoPanel.VertScrollBar.Position - WheelDelta div 2;
      Handled := True;
      Exit;
    end;
  end;
  Pt := FPaintBox.ScreenToClient(Mouse.CursorPos);
  if not FPaintBox.ClientRect.Contains(Pt) or (FCount = 0) then Exit;
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

{ ---------- controls / menu ---------- }

procedure TfrmReader.FormDropFiles(Sender: TObject; const FileNames: array of string);
var
  L: TStringList;
  i: Integer;
begin
  L := TStringList.Create;
  try
    for i := 0 to High(FileNames) do
      if FileExists(FileNames[i]) then L.Add(FileNames[i]);
    // dropped files are added to what is open (Open replaces)
    if L.Count > 0 then LoadFiles(L, FCount > 0);
  finally
    L.Free;
  end;
end;

procedure TfrmReader.ScrollBarChange(Sender: TObject);
begin
  if FUpdatingScroll then Exit;
  SetView(FirstTime + FScrollBar.Position * OneSecond + FViewSpan);
end;

procedure TfrmReader.CmbWindowChange(Sender: TObject);
begin
  if FCmbWindow.ItemIndex < 0 then Exit;
  if WindowSeconds[FCmbWindow.ItemIndex] = 0 then
    ShowAll
  else
    SetSpan(WindowSeconds[FCmbWindow.ItemIndex] * OneSecond);
end;

procedure TfrmReader.ChkStatsViewChange(Sender: TObject);
begin
  UpdateStats;
end;

procedure TfrmReader.MnuOpenClick(Sender: TObject);
begin
  if FOpenDialog.Execute then
    LoadFiles(FOpenDialog.Files, False);
end;

procedure TfrmReader.MnuAddClick(Sender: TObject);
begin
  if FOpenDialog.Execute then
    LoadFiles(FOpenDialog.Files, FCount > 0);
end;

procedure TfrmReader.MnuReloadClick(Sender: TObject);
var
  L: TStringList;
  i: Integer;
begin
  if Length(FFiles) = 0 then Exit;
  L := TStringList.Create;
  try
    for i := 0 to High(FFiles) do
      L.Add(FFiles[i].FileName);
    LoadFiles(L, False);
  finally
    L.Free;
  end;
end;

procedure TfrmReader.MnuExportPngClick(Sender: TObject);
var
  Bmp: TBGRABitmap;
  P: TBGRAChartPainter;
begin
  if FCount = 0 then Exit;
  FPngDialog.FileName := 'history_chart_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.png';
  if not FPngDialog.Execute then Exit;
  Bmp := TBGRABitmap.Create(FPaintBox.Width, FPaintBox.Height, BackColor);
  P := TBGRAChartPainter.Create(Bmp);
  try
    DrawChart(P, Bmp.Width, Bmp.Height, False);
    Bmp.SaveToFileUTF8(FPngDialog.FileName);
    FLblStatus.Caption := 'Chart exported to ' + FPngDialog.FileName;
  finally
    P.Free;
    Bmp.Free;
  end;
end;

procedure TfrmReader.MnuExportSvgClick(Sender: TObject);
var
  P: TSVGChartPainter;
begin
  if FCount = 0 then Exit;
  FSvgDialog.FileName := 'history_chart_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.svg';
  if not FSvgDialog.Execute then Exit;
  P := TSVGChartPainter.Create(FPaintBox.Width, FPaintBox.Height);
  try
    DrawChart(P, FPaintBox.Width, FPaintBox.Height, False);
    P.SaveToFile(FSvgDialog.FileName);
    FLblStatus.Caption := 'Vector chart exported to ' + FSvgDialog.FileName;
  finally
    P.Free;
  end;
end;

{ the samples in view, same format as HistoryRandomData (date-time) }
procedure TfrmReader.MnuExportCsvClick(Sender: TObject);
var
  SL: TStringList;
  i, s, i0, i1: Integer;
  L: string;
begin
  if FCount = 0 then Exit;
  FCsvDialog.FileName := 'history_view_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.csv';
  if not FCsvDialog.Execute then Exit;
  i0 := LowerBound(ViewStart);
  i1 := LowerBound(FViewEnd + OneMillisecond) - 1;
  SL := TStringList.Create;
  try
    L := 'Time';
    for s := 0 to FSeriesCount - 1 do
      L := L + ';' + FSeries[s].Name + ' [' + KindNames[FSeries[s].Kind] + ']';
    SL.Add(L);
    for i := i0 to i1 do
    begin
      L := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', FTimes[i]);
      for s := 0 to FSeriesCount - 1 do
        if IsNan(FData[s][i]) then
          L := L + ';'
        else
          case FSeries[s].Kind of
            dkBoolean: L := L + ';' + IfThen(FData[s][i] >= 0.5, 'TRUE', 'FALSE');
            dkByte, dkInteger: L := L + ';' + IntToStr(Round(FData[s][i]));
          else
            L := L + ';' + FormatFloat('0.000', FData[s][i], FS);
          end;
      SL.Add(L);
    end;
    SL.SaveToFile(FCsvDialog.FileName);
    FLblStatus.Caption := Format('%d samples exported to %s', [i1 - i0 + 1, FCsvDialog.FileName]);
  finally
    SL.Free;
  end;
end;

procedure TfrmReader.MnuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmReader.MnuUndoZoomClick(Sender: TObject);
begin
  UndoZoom;
  UpdateStatus;
end;

procedure TfrmReader.MnuShowAllClick(Sender: TObject);
var
  s: Integer;
begin
  SetLength(FZoomStack, 0);
  for s := 0 to FSeriesCount - 1 do
    FSeries[s].AxisUser := False;
  AutoAxes;
  ShowAll;
end;

procedure TfrmReader.MnuAutoAxesClick(Sender: TObject);
var
  s: Integer;
begin
  for s := 0 to FSeriesCount - 1 do
    FSeries[s].AxisUser := False;
  AutoAxes;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.MnuSeriesClick(Sender: TObject);
var
  s: Integer;
begin
  s := TMenuItem(Sender).Tag;
  FSeries[s].Visible := not FSeries[s].Visible;
  FLine[s].Visible := FSeries[s].Visible;
  TMenuItem(Sender).Checked := FSeries[s].Visible;
  if FLineVisChk[s] <> nil then
  begin
    FUpdatingLines := True;
    FLineVisChk[s].Checked := FSeries[s].Visible;
    FUpdatingLines := False;
  end;
  FPaintBox.Invalidate;
end;

procedure TfrmReader.MnuInfoClick(Sender: TObject);
begin
  FMnuInfo.Checked := not FMnuInfo.Checked;
  FInfoPanel.Visible := FMnuInfo.Checked;
  FInfoSplitter.Visible := FMnuInfo.Checked;
  if FInfoSplitter.Visible then
    FInfoSplitter.Left := FInfoPanel.Left - FInfoSplitter.Width;
end;

procedure TfrmReader.MnuDataGridClick(Sender: TObject);
begin
  FMnuDataGrid.Checked := not FMnuDataGrid.Checked;
  FDataGrid.Visible := FMnuDataGrid.Checked;
  FGridSplitter.Visible := FMnuDataGrid.Checked;
  if FDataGrid.Visible then
  begin
    FDataGrid.Top := FScrollBar.Top + FScrollBar.Height;
    FGridSplitter.Top := FDataGrid.Top - 1;
    UpdateDataGrid(True);
  end;
end;

procedure TfrmReader.MnuGridLinesClick(Sender: TObject);
begin
  FShowGrid := not FShowGrid;
  FMnuGridLines.Checked := FShowGrid;
  FPaintBox.Invalidate;
end;

end.
