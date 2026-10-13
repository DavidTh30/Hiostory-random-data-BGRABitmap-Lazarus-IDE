unit MainForm;

{
  History random data viewer
  --------------------------
  * 3 random data sets, one sample every 500 ms
  * On start, the last 3 hours of history are generated and written to
    history_data.csv. If the file already exists and is recent, it is
    loaded instead and the gap up to "now" is back-filled.
  * The generator panel sets any start / end time (day, month, year,
    hour, minute, second) and generates that range. When the end time is
    "now", live samples keep being added every 500 ms.
  * Drawn with BGRABitmap.
  * Every data set has its own Y axis; the axes sit side by side on the
    left. Drag an axis to move it up/down, mouse wheel over an axis zooms
    it, double-click resets it.
  * X axis (time): mouse wheel zooms in/out around the mouse, dragging the
    X axis (or the plot) scrolls in time, Shift+wheel scrolls too.
  * Main menu: File (Open, Save, Save As, Exit) and Panel.
  * Every data set can be renamed and saved to its own file.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DateUtils, Forms, Controls, Graphics, ExtCtrls,
  StdCtrls, Menus, Dialogs, Spin, Grids, LCLType, BGRABitmap, BGRABitmapTypes, ChartPainter;

const
  SampleMs = 500;
  SamplesPerSecond = 1000 div SampleMs;
  DefaultHistoryHours = 3;
  MaxRangeDays = 7;
  SeriesCount = 3;
  DataFileName = 'history_data.csv';
  YAxisMax = 140;
  AxisWidth = 58;
  XAxisHeight = 26;
  MinViewCount = 20; // 10 seconds

type
  { Data type of a set. The random walk always runs in floating point;
    the output sample is converted to the selected type. }
  TDataKind = (dkBoolean, dkByte, dkInteger, dkDouble);

  { How timestamps are written to the file }
  TTimeFormat = (tfDateTime, tfDouble);

  { Mean-reverting random walk followed by a low-pass filter.
    Smooth = filter factor (small = smoother), Jitter = raw noise. }
  TGenerator = record
    Name: string;
    Kind: TDataKind;
    Base, Amplitude, Smooth, Jitter: Double;
    Color: TBGRAPixel;
    Visible: Boolean;
    LineStyle: TPenStyle;     // psSolid, psDash, psDot, psDashDot, psDashDotDot
    LineWidth: Single;
    Target, Value: Double;
    BoolState: Boolean;       // Boolean output with hysteresis
  end;

  { Independent Y axis of one data set }
  TAxis = record
    Min, Max: Double;
  end;

  { Generator panel field ids (stored in the control's Tag) }
  TGenField = (gfBase, gfAmplitude, gfSmooth, gfJitter);

  { Day, Month, Year, Hour, Minute, Second }
  TDateTimeSpins = array[0..5] of TSpinEdit;

  { View saved before a rectangle zoom, for "Undo zoom" }
  TZoomState = record
    ViewStart, ViewCount: Integer;
    Axis: array[0..SeriesCount - 1] of TAxis;
  end;

  { TfrmMain }

  TfrmMain = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    // menu
    FMainMenu: TMainMenu;
    FMnuGenPanel, FMnuToolbar: TMenuItem;
    FOpenDialog: TOpenDialog;
    FSaveDialog: TSaveDialog;
    // toolbar
    FTopPanel: TPanel;
    FLblWindow, FLblStatus: TLabel;
    FCmbWindow: TComboBox;
    FChkFollow: TCheckBox;
    // generator panel
    FGenPanel: TScrollBox;
    FSplitter: TSplitter;
    FChkRunning: TCheckBox;
    FStartSpins, FEndSpins: TDateTimeSpins;
    FUpdatingGenPanel: Boolean;
    FSetGroup: array[0..SeriesCount - 1] of TGroupBox;
    FEdtName: array[0..SeriesCount - 1] of TEdit;
    FCmbKind: array[0..SeriesCount - 1] of TComboBox;
    FCmbTimeFormat: TComboBox;
    FCmbLineStyle: array[0..SeriesCount - 1] of TComboBox;
    FSpnLineWidth: array[0..SeriesCount - 1] of TFloatSpinEdit;
    // pin data panel
    FMnuPinPanel: TMenuItem;
    FPngDialog, FSvgDialog: TSaveDialog;
    FDayDirDialog: TSelectDirectoryDialog;
    FChkDaily: TCheckBox;
    FDailyDir: string;
    FChartPanel, FPinPanel: TPanel;
    FPinSplitter: TSplitter;
    FPinGrid: TStringGrid;
    FPinSpins: TDateTimeSpins;
    FPins: array of TDateTime;   // pinned sample times, ascending
    FTimeFormat: TTimeFormat;
    FSpins: array[0..SeriesCount - 1, TGenField] of TFloatSpinEdit;
    FChkVisible: array[0..SeriesCount - 1] of TCheckBox;
    FColorBtn: array[0..SeriesCount - 1] of TColorButton;
    // chart
    FPaintBox: TPaintBox;
    FScrollBar: TScrollBar;
    FTimer: TTimer;

    FGen: array[0..SeriesCount - 1] of TGenerator;
    FAxis: array[0..SeriesCount - 1] of TAxis;
    FTimes: array of TDateTime;
    FData: array[0..SeriesCount - 1] of array of Double;
    FCount: Integer;
    FNextTime: TDateTime;
    FSpanMs: Int64;           // length of the generated range

    FViewStart, FViewCount: Integer;
    FUpdatingScroll: Boolean;
    FHoverX, FHoverY: Integer;
    FDragging: Boolean;
    FDragX, FDragStart: Integer;
    FAxisDrag: Integer;       // index of Y axis being dragged, -1 = none
    FAxisDragY: Integer;
    FAxisDragMin: Double;
    FActiveAxis: Integer;     // axis whose grid lines are drawn
    FSelecting: Boolean;      // left-drag rectangle zoom in progress
    FSelStart, FSelEnd: TPoint;
    FZoomStack: array of TZoomState;
    FFS: TFormatSettings;
    FFilePath: string;

    procedure BuildMenu;
    procedure BuildUI;
    procedure BuildGeneratorPanel;
    procedure BuildPinPanel;
    function RenderChart(Interactive: Boolean): TBGRABitmap;
    procedure DrawChart(P: TChartPainter; W, H: Integer; Interactive: Boolean);
    function PinTableHeight: Integer;
    function FindIndex(T: TDateTime): Integer;
    function PinIndex(P: Integer): Integer;
    function SelectedPin: Integer;
    procedure AddPin(T: TDateTime; FromChart: Boolean);
    procedure RemovePin(P: Integer);
    procedure RefreshPinGrid;
    procedure GoToPin(P: Integer);
    function BuildDateTimeRow(AParent: TWinControl; const ACaption: string;
      ATop: Integer; out Spins: TDateTimeSpins): Integer;
    procedure SetDateTimeSpins(const Spins: TDateTimeSpins; T: TDateTime);
    function GetDateTimeSpins(const Spins: TDateTimeSpins; out T: TDateTime): Boolean;
    procedure SyncGeneratorPanel;
    procedure InitGenerators;
    procedure ResetAxis(S: Integer);
    function SpanSamples: Integer;
    function NextValue(var G: TGenerator): Double;
    function NextSample(var G: TGenerator): Double;
    procedure ResetWalk(var G: TGenerator);
    procedure RegenerateSeries(S: Integer);
    function FormatTime(T: TDateTime): string;
    function FormatValue(S: Integer; V: Double): string;
    function DisplayValue(S: Integer; V: Double): string;
    procedure ClearData;
    procedure AddSample(T: TDateTime);
    function SampleLine(Index: Integer): string;
    function HeaderLine: string;
    procedure AppendToFile(FromIndex: Integer);
    procedure AppendLines(const APath: string; FromIndex, ToIndex: Integer);
    function DailyFileName(const ADir: string; ADay: TDateTime): string;
    function WriteDailyFiles(const ADir: string; out Names: string): Integer;
    procedure AppendDaily(FromIndex: Integer);
    procedure SyncDailyFiles;
    procedure ChkDailyChange(Sender: TObject);
    procedure SaveToFile(const APath: string);
    procedure SaveSeriesToFile(S: Integer; const APath: string);
    procedure GenerateRange(AStart, AEnd: TDateTime);
    function LoadFromFile(const APath: string; out Recent: Boolean): Boolean;
    procedure CatchUpToNow;

    function VisibleAxisCount: Integer;
    function AxisLeft(S: Integer): Integer;
    function AxisAt(X, Y: Integer): Integer;
    function OnXAxis(X, Y: Integer): Boolean;
    function PlotRect: TRect;
    procedure ClampView;
    procedure UpdateScrollBar;
    procedure UpdateStatus;
    procedure ScrollTo(AStart: Integer);
    procedure SetWindowSeconds(Seconds: Integer);
    procedure ZoomX(Factor: Double; AnchorX: Integer);
    procedure SyncWindowCombo;
    procedure ShowLatest;
    procedure PushZoom;
    procedure UndoZoom;
    procedure ZoomToRect(const Sel: TRect);

    procedure TimerTick(Sender: TObject);
    procedure PaintBoxPaint(Sender: TObject);
    procedure ScrollBarChange(Sender: TObject);
    procedure CmbWindowChange(Sender: TObject);
    procedure ChkFollowChange(Sender: TObject);
    procedure PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseLeave(Sender: TObject);
    procedure PaintBoxDblClick(Sender: TObject);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);

    // menu handlers
    procedure MnuOpenClick(Sender: TObject);
    procedure MnuSaveClick(Sender: TObject);
    procedure MnuSaveAsClick(Sender: TObject);
    procedure MnuExitClick(Sender: TObject);
    procedure MnuGenPanelClick(Sender: TObject);
    procedure MnuToolbarClick(Sender: TObject);
    procedure MnuResetAxesClick(Sender: TObject);
    procedure MnuUndoZoomClick(Sender: TObject);
    procedure MnuPinPanelClick(Sender: TObject);
    procedure MnuExportPngClick(Sender: TObject);
    procedure MnuExportSvgClick(Sender: TObject);
    procedure MnuExportDailyClick(Sender: TObject);
    // pin panel handlers
    procedure BtnAddPinClick(Sender: TObject);
    procedure BtnRemovePinClick(Sender: TObject);
    procedure BtnClearPinsClick(Sender: TObject);
    procedure BtnGoToPinClick(Sender: TObject);
    procedure PinGridDblClick(Sender: TObject);
    procedure PinGridKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PinGridSelection(Sender: TObject; aCol, aRow: Integer);
    procedure MnuResetZoomClick(Sender: TObject);
    // generator panel handlers
    procedure GenSpinChange(Sender: TObject);
    procedure GenVisibleChange(Sender: TObject);
    procedure GenColorChange(Sender: TObject);
    procedure GenNameChange(Sender: TObject);
    procedure GenKindChange(Sender: TObject);
    procedure GenLineStyleChange(Sender: TObject);
    procedure GenLineWidthChange(Sender: TObject);
    procedure TimeFormatChange(Sender: TObject);
    procedure BtnSaveSetClick(Sender: TObject);
    procedure ChkRunningChange(Sender: TObject);
    procedure BtnLast3hClick(Sender: TObject);
    procedure BtnGenerateClick(Sender: TObject);
    procedure BtnDefaultsClick(Sender: TObject);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

const
  WindowSeconds: array[0..6] of Integer = (60, 300, 600, 900, 1800, 3600, 10800);
  WindowNames: array[0..6] of string = ('1 min', '5 min', '10 min', '15 min',
    '30 min', '1 hour', '3 hours');
  TimeSteps: array[0..15] of Integer = (5, 10, 15, 30, 60, 120, 300, 600, 900,
    1800, 3600, 7200, 10800, 21600, 43200, 86400);
  DefaultWindowIndex = 2; // 10 min
  FileFilter = 'CSV data (*.csv)|*.csv|All files (*.*)|*.*';
  DateTimeCaptions: array[0..5] of string = ('Day', 'Month', 'Year', 'Hour',
    'Minute', 'Second');
  KindNames: array[TDataKind] of string = ('Boolean', 'Byte', 'Integer', 'Double');
  TimeFormatNames: array[TTimeFormat] of string =
    ('Date-time  (yyyy-mm-dd hh:nn:ss.zzz)', 'Double  (TDateTime days)');
  DateTimeFileFormat = 'yyyy-mm-dd hh:nn:ss.zzz';
  LineStyles: array[0..4] of TPenStyle = (psSolid, psDash, psDot, psDashDot, psDashDotDot);
  LineStyleNames: array[0..4] of string = ('Solid', 'Dash', 'Dot', 'Dash dot', 'Dash dot dot');

{ Header column "Name [Type]" -> name and data type (Double if no type) }
procedure SplitHeaderName(const Field: string; out AName: string; out AKind: TDataKind);
var
  P: Integer;
  K: TDataKind;
  TypeName: string;
begin
  AName := Trim(Field);
  AKind := dkDouble;
  P := LastDelimiter('[', AName);
  if (P > 0) and (AName[Length(AName)] = ']') then
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

{ Timestamp in either file format; tells which one it was }
function ParseTime(const S: string; const FS: TFormatSettings; out T: TDateTime;
  out Fmt: TTimeFormat): Boolean;
var
  D: Double;
begin
  Result := True;
  if (Pos('-', S) > 1) or (Pos(':', S) > 0) then
  begin
    Fmt := tfDateTime;
    try
      T := ScanDateTime(DateTimeFileFormat, S);
    except
      Result := False;
    end;
  end
  else
  begin
    Fmt := tfDouble;
    Result := TryStrToFloat(S, D, FS);
    T := D;
  end;
end;

{ Sample value: TRUE / FALSE or a number }
function ParseValue(const S: string; const FS: TFormatSettings; out V: Double): Boolean;
begin
  Result := True;
  if SameText(S, 'TRUE') then V := 1
  else if SameText(S, 'FALSE') then V := 0
  else Result := TryStrToFloat(S, V, FS);
end;

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

{ Turns a data set name into something usable as a file name }
function SafeFileName(const S: string): string;
var
  i: Integer;
begin
  Result := Trim(S);
  for i := 1 to Length(Result) do
    if Result[i] in ['\', '/', ':', '*', '?', '"', '<', '>', '|'] then
      Result[i] := '_';
  if Result = '' then Result := 'dataset';
end;

{ TfrmMain }

procedure TfrmMain.FormCreate(Sender: TObject);
var
  Recent: Boolean;
  s: Integer;
begin
  Randomize;
  FFS := DefaultFormatSettings;
  FFS.DecimalSeparator := '.';
  FFilePath := ExtractFilePath(Application.ExeName) + DataFileName;
  FDailyDir := ExtractFilePath(Application.ExeName) + 'daily';
  FHoverX := -1;
  FAxisDrag := -1;
  FActiveAxis := 0;
  FSpanMs := Int64(DefaultHistoryHours) * 3600 * 1000;

  InitGenerators;
  for s := 0 to SeriesCount - 1 do
    ResetAxis(s);
  BuildMenu;
  BuildUI;
  FViewCount := WindowSeconds[DefaultWindowIndex] * SamplesPerSecond;

  // Default range: 3 hours before now .. now
  SetDateTimeSpins(FStartSpins, IncHour(Now, -DefaultHistoryHours));
  SetDateTimeSpins(FEndSpins, Now);

  // Reuse the existing file when it still reaches into the history window,
  // otherwise create a fresh history.
  if LoadFromFile(FFilePath, Recent) and Recent then
  begin
    CatchUpToNow;
    SyncDailyFiles;
  end
  else
    GenerateRange(IncHour(Now, -DefaultHistoryHours), Now);

  // axis ranges depend on the data types read from the file
  for s := 0 to SeriesCount - 1 do
    ResetAxis(s);
  SyncGeneratorPanel;
  RefreshPinGrid;
  ShowLatest;
  FTimer.Enabled := FChkRunning.Checked;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  FTimer.Enabled := False;
end;

{ ---------- UI construction ---------- }

procedure TfrmMain.BuildMenu;
var
  MFile, MPanel, Item: TMenuItem;

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
  FMainMenu := TMainMenu.Create(Self);
  Menu := FMainMenu;

  MFile := TMenuItem.Create(FMainMenu);
  MFile.Caption := '&File';
  FMainMenu.Items.Add(MFile);
  AddItem(MFile, '&Open...', @MnuOpenClick, ShortCut(Ord('O'), [ssCtrl]));
  AddItem(MFile, '&Save', @MnuSaveClick, ShortCut(Ord('S'), [ssCtrl]));
  AddItem(MFile, 'Save &As...', @MnuSaveAsClick, ShortCut(Ord('S'), [ssCtrl, ssShift]));
  AddItem(MFile, '-', nil);
  AddItem(MFile, '&Export chart as PNG...', @MnuExportPngClick, ShortCut(Ord('E'), [ssCtrl]));
  AddItem(MFile, 'Export chart as S&VG (vector)...', @MnuExportSvgClick,
    ShortCut(Ord('E'), [ssCtrl, ssShift]));
  AddItem(MFile, 'Export CSV, one file per &day...', @MnuExportDailyClick,
    ShortCut(Ord('D'), [ssCtrl]));
  AddItem(MFile, '-', nil);
  AddItem(MFile, 'E&xit', @MnuExitClick, ShortCut(Ord('Q'), [ssCtrl]));

  MPanel := TMenuItem.Create(FMainMenu);
  MPanel.Caption := '&Panel';
  FMainMenu.Items.Add(MPanel);
  FMnuGenPanel := AddItem(MPanel, 'Random data &generator', @MnuGenPanelClick,
    ShortCut(Ord('G'), [ssCtrl]));
  FMnuGenPanel.Checked := True;
  FMnuToolbar := AddItem(MPanel, '&Toolbar', @MnuToolbarClick);
  FMnuToolbar.Checked := True;
  FMnuPinPanel := AddItem(MPanel, '&Pin data', @MnuPinPanelClick, ShortCut(Ord('P'), [ssCtrl]));
  FMnuPinPanel.Checked := True;
  AddItem(MPanel, '-', nil);
  Item := AddItem(MPanel, '&Reset Y axes', @MnuResetAxesClick, ShortCut(Ord('R'), [ssCtrl]));
  Item.Hint := 'Reset all Y axes to 0..' + IntToStr(YAxisMax);
  AddItem(MPanel, '&Undo zoom', @MnuUndoZoomClick, ShortCut(Ord('Z'), [ssCtrl]));
  AddItem(MPanel, 'Reset &zoom', @MnuResetZoomClick, ShortCut(Ord('0'), [ssCtrl]));

  FOpenDialog := TOpenDialog.Create(Self);
  FOpenDialog.Filter := FileFilter;
  FOpenDialog.DefaultExt := 'csv';
  FOpenDialog.Options := FOpenDialog.Options + [ofFileMustExist];

  FSaveDialog := TSaveDialog.Create(Self);
  FSaveDialog.Filter := FileFilter;
  FSaveDialog.DefaultExt := 'csv';
  FSaveDialog.Options := FSaveDialog.Options + [ofOverwritePrompt];

  FPngDialog := TSaveDialog.Create(Self);
  FPngDialog.Title := 'Export chart as PNG';
  FPngDialog.Filter := 'PNG image (*.png)|*.png';
  FPngDialog.DefaultExt := 'png';
  FPngDialog.Options := FPngDialog.Options + [ofOverwritePrompt];

  FSvgDialog := TSaveDialog.Create(Self);
  FSvgDialog.Title := 'Export chart as SVG (vector)';
  FSvgDialog.Filter := 'SVG vector image (*.svg)|*.svg';
  FSvgDialog.DefaultExt := 'svg';
  FSvgDialog.Options := FSvgDialog.Options + [ofOverwritePrompt];

  FDayDirDialog := TSelectDirectoryDialog.Create(Self);
  FDayDirDialog.Title := 'Folder for the daily CSV files';
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
  FTopPanel.Height := 36;
  FTopPanel.BevelOuter := bvNone;

  FLblWindow := TLabel.Create(Self);
  FLblWindow.Parent := FTopPanel;
  FLblWindow.SetBounds(10, 10, 50, 20);
  FLblWindow.Caption := 'Window:';

  FCmbWindow := TComboBox.Create(Self);
  FCmbWindow.Parent := FTopPanel;
  FCmbWindow.SetBounds(64, 6, 90, 24);
  FCmbWindow.Style := csDropDownList;
  for i := Low(WindowNames) to High(WindowNames) do
    FCmbWindow.Items.Add(WindowNames[i]);
  FCmbWindow.ItemIndex := DefaultWindowIndex;
  FCmbWindow.OnChange := @CmbWindowChange;

  FChkFollow := TCheckBox.Create(Self);
  FChkFollow.Parent := FTopPanel;
  FChkFollow.SetBounds(170, 9, 90, 20);
  FChkFollow.Caption := 'Follow live';
  FChkFollow.Checked := True;
  FChkFollow.OnChange := @ChkFollowChange;

  FLblStatus := TLabel.Create(Self);
  FLblStatus.Parent := FTopPanel;
  FLblStatus.SetBounds(280, 10, 800, 20);

  BuildGeneratorPanel;

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align := alRight;
  FSplitter.Left := FGenPanel.Left - 5;

  // pin data panel at the bottom, under the chart
  BuildPinPanel;
  FPinSplitter := TSplitter.Create(Self);
  FPinSplitter.Parent := Self;
  FPinSplitter.Align := alBottom;
  FPinSplitter.Top := FPinPanel.Top - 5;

  // chart: paint box + time scrollbar
  FChartPanel := TPanel.Create(Self);
  FChartPanel.Parent := Self;
  FChartPanel.Align := alClient;
  FChartPanel.BevelOuter := bvNone;
  FChartPanel.DoubleBuffered := True;

  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Parent := FChartPanel;
  FScrollBar.Kind := sbHorizontal;
  FScrollBar.Align := alBottom;
  FScrollBar.OnChange := @ScrollBarChange;

  FPaintBox := TPaintBox.Create(Self);
  FPaintBox.Parent := FChartPanel;
  FPaintBox.Align := alClient;
  FPaintBox.OnPaint := @PaintBoxPaint;
  FPaintBox.OnMouseDown := @PaintBoxMouseDown;
  FPaintBox.OnMouseMove := @PaintBoxMouseMove;
  FPaintBox.OnMouseUp := @PaintBoxMouseUp;
  FPaintBox.OnMouseLeave := @PaintBoxMouseLeave;
  FPaintBox.OnDblClick := @PaintBoxDblClick;

  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := SampleMs;
  FTimer.OnTimer := @TimerTick;
end;

{ Caption + two rows of spin edits (Day Month Year / Hour Minute Second).
  Returns the Y position below the block. }
function TfrmMain.BuildDateTimeRow(AParent: TWinControl; const ACaption: string;
  ATop: Integer; out Spins: TDateTimeSpins): Integer;
const
  ColX: array[0..2] of Integer = (10, 72, 134);
  ColW: array[0..2] of Integer = (58, 58, 74);
  MinV: array[0..5] of Integer = (1, 1, 2000, 0, 0, 0);
  MaxV: array[0..5] of Integer = (31, 12, 2100, 23, 59, 59);
var
  Lbl: TLabel;
  i, Row, Col: Integer;
begin
  Lbl := TLabel.Create(Self);
  Lbl.Parent := AParent;
  Lbl.SetBounds(10, ATop, 200, 18);
  Lbl.Caption := ACaption;
  Lbl.Font.Style := [fsBold];

  for i := 0 to 5 do
  begin
    Row := i div 3;
    Col := i mod 3;
    Lbl := TLabel.Create(Self);
    Lbl.Parent := AParent;
    Lbl.SetBounds(ColX[Col], ATop + 20 + Row * 44, ColW[Col], 16);
    Lbl.Caption := DateTimeCaptions[i];

    Spins[i] := TSpinEdit.Create(Self);
    Spins[i].Parent := AParent;
    Spins[i].SetBounds(ColX[Col], ATop + 36 + Row * 44, ColW[Col], 24);
    Spins[i].MinValue := MinV[i];
    Spins[i].MaxValue := MaxV[i];
  end;
  Result := ATop + 36 + 44 + 30;
end;

procedure TfrmMain.SetDateTimeSpins(const Spins: TDateTimeSpins; T: TDateTime);
var
  Y, Mo, D, H, Mi, S, MS: Word;
begin
  DecodeDateTime(T, Y, Mo, D, H, Mi, S, MS);
  Spins[0].Value := D;
  Spins[1].Value := Mo;
  Spins[2].Value := Y;
  Spins[3].Value := H;
  Spins[4].Value := Mi;
  Spins[5].Value := S;
end;

function TfrmMain.GetDateTimeSpins(const Spins: TDateTimeSpins; out T: TDateTime): Boolean;
begin
  Result := TryEncodeDateTime(Spins[2].Value, Spins[1].Value, Spins[0].Value,
    Spins[3].Value, Spins[4].Value, Spins[5].Value, 0, T);
end;

procedure TfrmMain.BuildGeneratorPanel;
const
  FieldCaptions: array[TGenField] of string =
    ('Base level', 'Amplitude (height)', 'Smoothing (0.01 = smooth)', 'Noise / jitter');
  FieldMin: array[TGenField] of Double = (-1000, 0, 0.005, 0);
  FieldMax: array[TGenField] of Double = (1000, 500, 1, 100);
  FieldInc: array[TGenField] of Double = (1, 1, 0.01, 0.1);
  FieldDec: array[TGenField] of Integer = (1, 1, 3, 2);
var
  Grp: TGroupBox;
  Lbl: TLabel;
  Btn: TButton;
  s, i, Y, YY: Integer;
  f: TGenField;
  K: TDataKind;
  TF: TTimeFormat;
begin
  FGenPanel := TScrollBox.Create(Self);
  FGenPanel.Parent := Self;
  FGenPanel.Align := alRight;
  FGenPanel.Width := 250;
  FGenPanel.HorzScrollBar.Visible := False;
  FGenPanel.BorderStyle := bsNone;

  // --- common settings: live flag + time range ---
  Grp := TGroupBox.Create(Self);
  Grp.Parent := FGenPanel;
  Grp.Caption := ' Random data generator ';

  FChkRunning := TCheckBox.Create(Self);
  FChkRunning.Parent := Grp;
  FChkRunning.SetBounds(10, 4, 200, 20);
  FChkRunning.Caption := 'Generate live data (every 500 ms)';
  FChkRunning.Checked := True;
  FChkRunning.OnChange := @ChkRunningChange;

  YY := BuildDateTimeRow(Grp, 'Start time', 32, FStartSpins);
  YY := BuildDateTimeRow(Grp, 'End time', YY, FEndSpins);

  Btn := TButton.Create(Self);
  Btn.Parent := Grp;
  Btn.SetBounds(10, YY, 98, 28);
  Btn.Caption := 'Last 3 hours';
  Btn.Hint := 'Start = now - 3 hours, End = now';
  Btn.ShowHint := True;
  Btn.OnClick := @BtnLast3hClick;

  Btn := TButton.Create(Self);
  Btn.Parent := Grp;
  Btn.SetBounds(112, YY, 96, 28);
  Btn.Caption := 'Defaults';
  Btn.Hint := 'Restore the default generator settings';
  Btn.ShowHint := True;
  Btn.OnClick := @BtnDefaultsClick;

  Btn := TButton.Create(Self);
  Btn.Parent := Grp;
  Btn.SetBounds(10, YY + 34, 198, 30);
  Btn.Caption := 'Generate';
  Btn.Font.Style := [fsBold];
  Btn.Hint := 'Create new random data for the start..end range' + LineEnding +
    'and overwrite the current file';
  Btn.ShowHint := True;
  Btn.OnClick := @BtnGenerateClick;

  // timestamp format used in the file
  Lbl := TLabel.Create(Self);
  Lbl.Parent := Grp;
  Lbl.SetBounds(10, YY + 72, 200, 18);
  Lbl.Caption := 'Timestamp format';
  Lbl.Font.Style := [fsBold];

  FCmbTimeFormat := TComboBox.Create(Self);
  FCmbTimeFormat.Parent := Grp;
  FCmbTimeFormat.SetBounds(10, YY + 90, 198, 24);
  FCmbTimeFormat.Style := csDropDownList;
  for TF := Low(TTimeFormat) to High(TTimeFormat) do
    FCmbTimeFormat.Items.Add(TimeFormatNames[TF]);
  FCmbTimeFormat.ItemIndex := Ord(tfDateTime);
  FCmbTimeFormat.Hint := 'How timestamps are written to the file.' + LineEnding +
    'Changing it rewrites the current file.';
  FCmbTimeFormat.ShowHint := True;
  FCmbTimeFormat.OnChange := @TimeFormatChange;

  // one CSV file per calendar day
  FChkDaily := TCheckBox.Create(Self);
  FChkDaily.Parent := Grp;
  FChkDaily.SetBounds(10, YY + 122, 200, 20);
  FChkDaily.Caption := 'One CSV file per day (daily\)';
  FChkDaily.Checked := True;
  FChkDaily.Hint := 'Generate also writes one file per day into the "daily" folder,' + LineEnding +
    'named after the date, e.g. history_data_2026-10-13.csv.' + LineEnding +
    'Live samples are appended to the file of their day.';
  FChkDaily.ShowHint := True;
  FChkDaily.OnChange := @ChkDailyChange;

  Grp.SetBounds(6, 4, 222, YY + 122 + 22 + 28);
  Y := Grp.Top + Grp.Height + 8;

  // --- one group per data set ---
  for s := 0 to SeriesCount - 1 do
  begin
    Grp := TGroupBox.Create(Self);
    Grp.Parent := FGenPanel;
    Grp.SetBounds(6, Y, 222, 378);
    Grp.Caption := ' ' + FGen[s].Name + ' ';
    FSetGroup[s] := Grp;

    Lbl := TLabel.Create(Self);
    Lbl.Parent := Grp;
    Lbl.SetBounds(10, 9, 40, 18);
    Lbl.Caption := 'Name';

    FEdtName[s] := TEdit.Create(Self);
    FEdtName[s].Parent := Grp;
    FEdtName[s].SetBounds(52, 4, 156, 24);
    FEdtName[s].Tag := s;
    FEdtName[s].OnChange := @GenNameChange;

    Lbl := TLabel.Create(Self);
    Lbl.Parent := Grp;
    Lbl.SetBounds(10, 39, 40, 18);
    Lbl.Caption := 'Type';

    FCmbKind[s] := TComboBox.Create(Self);
    FCmbKind[s].Parent := Grp;
    FCmbKind[s].SetBounds(52, 34, 156, 24);
    FCmbKind[s].Style := csDropDownList;
    for K := Low(TDataKind) to High(TDataKind) do
      FCmbKind[s].Items.Add(KindNames[K]);
    FCmbKind[s].Tag := s;
    FCmbKind[s].Hint := 'Data type of the samples.' + LineEnding +
      'Changing it regenerates this set for the whole time range.';
    FCmbKind[s].ShowHint := True;
    FCmbKind[s].OnChange := @GenKindChange;

    FChkVisible[s] := TCheckBox.Create(Self);
    FChkVisible[s].Parent := Grp;
    FChkVisible[s].SetBounds(10, 72, 80, 20);
    FChkVisible[s].Caption := 'Visible';
    FChkVisible[s].Tag := s;
    FChkVisible[s].OnChange := @GenVisibleChange;

    FColorBtn[s] := TColorButton.Create(Self);
    FColorBtn[s].Parent := Grp;
    FColorBtn[s].SetBounds(110, 68, 98, 26);
    FColorBtn[s].Caption := 'Color';
    FColorBtn[s].Tag := s;
    FColorBtn[s].OnColorChanged := @GenColorChange;

    Lbl := TLabel.Create(Self);
    Lbl.Parent := Grp;
    Lbl.SetBounds(10, 105, 40, 18);
    Lbl.Caption := 'Line';

    FCmbLineStyle[s] := TComboBox.Create(Self);
    FCmbLineStyle[s].Parent := Grp;
    FCmbLineStyle[s].SetBounds(52, 100, 98, 24);
    FCmbLineStyle[s].Style := csDropDownList;
    for i := Low(LineStyles) to High(LineStyles) do
      FCmbLineStyle[s].Items.Add(LineStyleNames[i]);
    FCmbLineStyle[s].Tag := s;
    FCmbLineStyle[s].Hint := 'Line style';
    FCmbLineStyle[s].ShowHint := True;
    FCmbLineStyle[s].OnChange := @GenLineStyleChange;

    FSpnLineWidth[s] := TFloatSpinEdit.Create(Self);
    FSpnLineWidth[s].Parent := Grp;
    FSpnLineWidth[s].SetBounds(154, 100, 54, 24);
    FSpnLineWidth[s].MinValue := 0.5;
    FSpnLineWidth[s].MaxValue := 8;
    FSpnLineWidth[s].Increment := 0.5;
    FSpnLineWidth[s].DecimalPlaces := 1;
    FSpnLineWidth[s].Tag := s;
    FSpnLineWidth[s].Hint := 'Line thickness (pixels)';
    FSpnLineWidth[s].ShowHint := True;
    FSpnLineWidth[s].OnChange := @GenLineWidthChange;

    Btn := TButton.Create(Self);
    Btn.Parent := Grp;
    Btn.SetBounds(10, 132, 198, 26);
    Btn.Caption := 'Save this data set...';
    Btn.Tag := s;
    Btn.OnClick := @BtnSaveSetClick;

    YY := 164;
    for f := Low(TGenField) to High(TGenField) do
    begin
      Lbl := TLabel.Create(Self);
      Lbl.Parent := Grp;
      Lbl.SetBounds(10, YY, 200, 18);
      Lbl.Caption := FieldCaptions[f];

      FSpins[s, f] := TFloatSpinEdit.Create(Self);
      FSpins[s, f].Parent := Grp;
      FSpins[s, f].SetBounds(10, YY + 18, 198, 24);
      FSpins[s, f].MinValue := FieldMin[f];
      FSpins[s, f].MaxValue := FieldMax[f];
      FSpins[s, f].Increment := FieldInc[f];
      FSpins[s, f].DecimalPlaces := FieldDec[f];
      FSpins[s, f].Tag := s * 10 + Ord(f);
      FSpins[s, f].OnChange := @GenSpinChange;
      Inc(YY, 50);
    end;
    Inc(Y, Grp.Height + 8);
  end;
end;

procedure TfrmMain.SyncGeneratorPanel;
var
  s, i: Integer;
begin
  FUpdatingGenPanel := True;
  try
    for s := 0 to SeriesCount - 1 do
    begin
      FEdtName[s].Text := FGen[s].Name;
      FSetGroup[s].Caption := ' ' + FGen[s].Name + ' ';
      FSpins[s, gfBase].Value := FGen[s].Base;
      FSpins[s, gfAmplitude].Value := FGen[s].Amplitude;
      FSpins[s, gfSmooth].Value := FGen[s].Smooth;
      FSpins[s, gfJitter].Value := FGen[s].Jitter;
      FChkVisible[s].Checked := FGen[s].Visible;
      FColorBtn[s].ButtonColor := RGBToColor(FGen[s].Color.red,
        FGen[s].Color.green, FGen[s].Color.blue);
      FCmbKind[s].ItemIndex := Ord(FGen[s].Kind);
      FCmbLineStyle[s].ItemIndex := 0;
      for i := Low(LineStyles) to High(LineStyles) do
        if LineStyles[i] = FGen[s].LineStyle then FCmbLineStyle[s].ItemIndex := i;
      FSpnLineWidth[s].Value := FGen[s].LineWidth;
    end;
    FCmbTimeFormat.ItemIndex := Ord(FTimeFormat);
  finally
    FUpdatingGenPanel := False;
  end;
end;

{ ---------- data generation ---------- }

procedure TfrmMain.InitGenerators;

  procedure Setup(Idx: Integer; const AName: string; ABase, AAmp, ASmooth,
    AJitter: Double; AColor: TBGRAPixel);
  begin
    with FGen[Idx] do
    begin
      Name := AName;
      Kind := dkDouble;
      Base := ABase;
      Amplitude := AAmp;
      Smooth := ASmooth;
      Jitter := AJitter;
      Color := AColor;
      Visible := True;
      LineStyle := psSolid;
      LineWidth := 1.5;
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

procedure TfrmMain.ResetAxis(S: Integer);
begin
  case FGen[S].Kind of
    dkBoolean:
      begin
        // keep FALSE / TRUE clearly apart and off the frame
        FAxis[S].Min := -0.25;
        FAxis[S].Max := 1.25;
      end;
    dkByte:
      begin
        FAxis[S].Min := 0;
        FAxis[S].Max := Max(YAxisMax, 255);
      end;
  else
    FAxis[S].Min := 0;
    FAxis[S].Max := YAxisMax;
  end;
end;

function TfrmMain.SpanSamples: Integer;
begin
  Result := FSpanMs div SampleMs + 1;
end;

function TfrmMain.NextValue(var G: TGenerator): Double;
begin
  // Random walk of the target, pulled back towards the base level
  G.Target := G.Target + RandG(0, G.Amplitude * 0.15);
  G.Target := G.Target + (G.Base - G.Target) * 0.02;
  G.Target := EnsureRange(G.Target, G.Base - G.Amplitude, G.Base + G.Amplitude);
  // Low-pass towards the target plus some raw noise
  G.Value := G.Value + G.Smooth * (G.Target - G.Value) + RandG(0, G.Jitter);
  G.Value := EnsureRange(G.Value, -1e6, 1e6);
  Result := G.Value;
end;

{ Next random walk value converted to the data type of the set.
  Boolean: TRUE above the base level, FALSE below it, with a little
  hysteresis so a smooth set switches rarely and a rough set often. }
function TfrmMain.NextSample(var G: TGenerator): Double;
var
  V, Band: Double;
begin
  V := NextValue(G);
  case G.Kind of
    dkBoolean:
      begin
        Band := G.Amplitude * 0.1;
        if G.BoolState then
          G.BoolState := V >= G.Base - Band
        else
          G.BoolState := V > G.Base + Band;
        Result := Ord(G.BoolState);
      end;
    dkByte: Result := EnsureRange(Round(V), 0, 255);
    dkInteger: Result := Round(V);
  else
    Result := V;
  end;
end;

procedure TfrmMain.ResetWalk(var G: TGenerator);
begin
  G.Target := G.Base;
  G.Value := G.Base;
  G.BoolState := False;
end;

{ New random values of one set for all existing timestamps, e.g. after
  its data type changed. The other sets are kept. }
procedure TfrmMain.RegenerateSeries(S: Integer);
var
  i: Integer;
begin
  ResetWalk(FGen[S]);
  for i := 0 to FCount - 1 do
    FData[S][i] := NextSample(FGen[S]);
end;

{ Timestamp as written to the file }
function TfrmMain.FormatTime(T: TDateTime): string;
var
  MyDouble: Double;
begin
  if FTimeFormat = tfDouble then
  begin
    // TDateTime is a Double: days since 30/12/1899, time as the fraction
    MyDouble := T;
    Result := MyDouble.ToString(FFS);
  end
  else
    Result := FormatDateTime(DateTimeFileFormat, T);
end;

{ Sample value as written to the file, depending on the data type }
function TfrmMain.FormatValue(S: Integer; V: Double): string;
begin
  case FGen[S].Kind of
    dkBoolean: if V >= 0.5 then Result := 'TRUE' else Result := 'FALSE';
    dkByte, dkInteger: Result := IntToStr(Round(V));
  else
    Result := FormatFloat('0.000', V, FFS);
  end;
end;

{ Sample value as shown in the chart }
function TfrmMain.DisplayValue(S: Integer; V: Double): string;
begin
  case FGen[S].Kind of
    dkBoolean: if V >= 0.5 then Result := 'True' else Result := 'False';
    dkByte, dkInteger: Result := IntToStr(Round(V));
  else
    Result := FormatFloat('0.00', V);
  end;
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
    NewCap := Max(SpanSamples + 1024, Length(FTimes) * 2);
    SetLength(FTimes, NewCap);
    for s := 0 to SeriesCount - 1 do
      SetLength(FData[s], NewCap);
  end;
  FTimes[FCount] := T;
  for s := 0 to SeriesCount - 1 do
    FData[s][FCount] := NextSample(FGen[s]);
  Inc(FCount);
end;

function TfrmMain.SampleLine(Index: Integer): string;
var
  s: Integer;
begin
  Result := FormatTime(FTimes[Index]);
  for s := 0 to SeriesCount - 1 do
    Result := Result + ';' + FormatValue(s, FData[s][Index]);
end;

{ "Time;Name 1 [Double];Name 2 [Boolean];..." - the type in brackets lets
  the file be loaded back with the same data types }
function TfrmMain.HeaderLine: string;
var
  s: Integer;
begin
  Result := 'Time';
  for s := 0 to SeriesCount - 1 do
    Result := Result + ';' + FGen[s].Name + ' [' + KindNames[FGen[s].Kind] + ']';
end;

procedure TfrmMain.AppendToFile(FromIndex: Integer);
var
  F: TFileStream;
  Buf: string;
  i: Integer;
begin
  if FromIndex >= FCount then Exit;
  AppendLines(FFilePath, FromIndex, FCount - 1);
  if FChkDaily.Checked then
    AppendDaily(FromIndex);
end;

{ Appends samples FromIndex..ToIndex to APath (header first if it is new) }
procedure TfrmMain.AppendLines(const APath: string; FromIndex, ToIndex: Integer);
var
  F: TFileStream;
  Buf: string;
  i: Integer;
begin
  if FromIndex > ToIndex then Exit;
  Buf := '';
  for i := FromIndex to ToIndex do
    Buf := Buf + SampleLine(i) + LineEnding;
  try
    if FileExists(APath) then
    begin
      F := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyWrite);
      F.Seek(0, soEnd);
    end
    else
    begin
      ForceDirectories(ExtractFileDir(APath));
      F := TFileStream.Create(APath, fmCreate);
      Buf := HeaderLine + LineEnding + Buf;
    end;
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

{ <dir>\<main file name>_yyyy-mm-dd.csv }
function TfrmMain.DailyFileName(const ADir: string; ADay: TDateTime): string;
begin
  Result := IncludeTrailingPathDelimiter(ADir) +
    ChangeFileExt(ExtractFileName(FFilePath), '') + '_' +
    FormatDateTime('yyyy-mm-dd', ADay) + '.csv';
end;

{ Splits all data into one CSV file per calendar day (files of those days
  are overwritten). Returns the number of files; Names lists them. }
function TfrmMain.WriteDailyFiles(const ADir: string; out Names: string): Integer;
var
  SL: TStringList;
  i, Day, CurDay: Integer;
  FileName: string;
begin
  Result := 0;
  Names := '';
  if FCount = 0 then Exit;
  ForceDirectories(ADir);
  SL := TStringList.Create;
  try
    CurDay := Trunc(FTimes[0]);
    SL.Add(HeaderLine);
    for i := 0 to FCount do
    begin
      if i < FCount then Day := Trunc(FTimes[i]) else Day := -1;
      if Day <> CurDay then
      begin
        // day finished -> write its file
        FileName := DailyFileName(ADir, CurDay);
        SL.SaveToFile(FileName);
        Inc(Result);
        Names := Names + ExtractFileName(FileName) + LineEnding;
        SL.Clear;
        SL.Add(HeaderLine);
        CurDay := Day;
      end;
      if i < FCount then
        SL.Add(SampleLine(i));
    end;
  finally
    SL.Free;
  end;
end;

{ Rewrites the daily files from all data, so they match the main file }
procedure TfrmMain.SyncDailyFiles;
var
  Names: string;
  Files: Integer;
begin
  if not FChkDaily.Checked or (FCount = 0) then Exit;
  try
    Files := WriteDailyFiles(FDailyDir, Names);
    FLblStatus.Caption := Format('%d daily file(s) in %s', [Files, FDailyDir]);
  except
    on E: Exception do
      FLblStatus.Caption := 'Daily file write error: ' + E.Message;
  end;
end;

procedure TfrmMain.ChkDailyChange(Sender: TObject);
begin
  SyncDailyFiles;
end;

{ Live samples go to the file of their own day; after midnight a new
  daily file is started automatically. }
procedure TfrmMain.AppendDaily(FromIndex: Integer);
var
  i, First: Integer;
begin
  First := FromIndex;
  for i := FromIndex to FCount - 1 do
    if (i = FCount - 1) or (Trunc(FTimes[i + 1]) <> Trunc(FTimes[i])) then
    begin
      AppendLines(DailyFileName(FDailyDir, Trunc(FTimes[i])), First, i);
      First := i + 1;
    end;
end;

procedure TfrmMain.SaveToFile(const APath: string);
var
  SL: TStringList;
  i: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Capacity := FCount + 1;
    SL.Add(HeaderLine);
    for i := 0 to FCount - 1 do
      SL.Add(SampleLine(i));
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

{ Writes one data set: "Time;<name> [<type>]" }
procedure TfrmMain.SaveSeriesToFile(S: Integer; const APath: string);
var
  SL: TStringList;
  i: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Capacity := FCount + 1;
    SL.Add('Time;' + FGen[S].Name + ' [' + KindNames[FGen[S].Kind] + ']');
    for i := 0 to FCount - 1 do
      SL.Add(FormatTime(FTimes[i]) + ';' + FormatValue(S, FData[S][i]));
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

{ New random data from AStart to AEnd (500 ms steps), saved to FFilePath.
  When AEnd is "now", live generation continues afterwards. }
procedure TfrmMain.GenerateRange(AStart, AEnd: TDateTime);
var
  i, N, s, Files: Integer;
  Live: Boolean;
  Names: string;
begin
  if AEnd > Now then AEnd := Now;
  Live := MilliSecondsBetween(Now, AEnd) <= 5000;
  FSpanMs := Max(Int64(SampleMs), MilliSecondsBetween(AEnd, AStart));
  N := SpanSamples;

  Screen.Cursor := crHourGlass;
  try
    ClearData;
    for s := 0 to SeriesCount - 1 do
      ResetWalk(FGen[s]);
    for i := 0 to N - 1 do
      AddSample(IncMilliSecond(AStart, Int64(i) * SampleMs));
    FNextTime := IncMilliSecond(FTimes[FCount - 1], SampleMs);
    try
      SaveToFile(FFilePath);
      // historical data over several days -> a new file for each day
      if FChkDaily.Checked then
      begin
        Files := WriteDailyFiles(FDailyDir, Names);
        FLblStatus.Caption := Format('%d daily file(s) written to %s', [Files, FDailyDir]);
      end;
    except
      on E: Exception do
        MessageDlg('Cannot write ' + FFilePath + LineEnding + E.Message, mtError, [mbOK], 0);
    end;
  finally
    Screen.Cursor := crDefault;
  end;

  FChkRunning.Checked := Live;
  FTimer.Enabled := Live;
end;

{ Loads APath. Recent = the last sample is inside the history window, so
  live generation can simply continue after it. Data set names and types
  are taken from the header line, the timestamp format from the data. }
function TfrmMain.LoadFromFile(const APath: string; out Recent: Boolean): Boolean;
var
  SL, Parts: TStringList;
  i, s, NewCap: Integer;
  T: TDateTime;
  TF: TTimeFormat;
  Kind: TDataKind;
  NewName: string;
  Vals: array[0..SeriesCount - 1] of Double;
  Ok: Boolean;
begin
  Result := False;
  Recent := False;
  if not FileExists(APath) then Exit;

  SL := TStringList.Create;
  Parts := TStringList.Create;
  try
    try
      SL.LoadFromFile(APath);
    except
      Exit;
    end;
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;

    ClearData;
    NewCap := SL.Count + 1024;
    SetLength(FTimes, NewCap);
    for s := 0 to SeriesCount - 1 do
      SetLength(FData[s], NewCap);

    for i := 0 to SL.Count - 1 do
    begin
      Parts.DelimitedText := SL[i];
      if Parts.Count < SeriesCount + 1 then Continue;
      if SameText(Parts[0], 'Time') then
      begin
        // header: "Name [Type]" per data set
        for s := 0 to SeriesCount - 1 do
          if Trim(Parts[s + 1]) <> '' then
          begin
            SplitHeaderName(Parts[s + 1], NewName, Kind);
            if NewName <> '' then FGen[s].Name := NewName;
            FGen[s].Kind := Kind;
          end;
        Continue;
      end;
      if not ParseTime(Parts[0], FFS, T, TF) then Continue;
      Ok := True;
      for s := 0 to SeriesCount - 1 do
        if not ParseValue(Trim(Parts[s + 1]), FFS, Vals[s]) then Ok := False;
      if not Ok then Continue; // malformed line
      if FCount = 0 then
        FTimeFormat := TF;     // keep writing in the format of the file
      FTimes[FCount] := T;
      for s := 0 to SeriesCount - 1 do
        FData[s][FCount] := Vals[s];
      Inc(FCount);
    end;
  finally
    Parts.Free;
    SL.Free;
  end;

  if FCount = 0 then Exit;

  // Continue the random walks from the last stored values
  for s := 0 to SeriesCount - 1 do
    if FGen[s].Kind = dkBoolean then
    begin
      ResetWalk(FGen[s]);
      FGen[s].BoolState := FData[s][FCount - 1] >= 0.5;
    end
    else
    begin
      FGen[s].Value := FData[s][FCount - 1];
      FGen[s].Target := FData[s][FCount - 1];
    end;
  FSpanMs := Max(Int64(SampleMs), MilliSecondsBetween(FTimes[FCount - 1], FTimes[0]));
  FNextTime := IncMilliSecond(FTimes[FCount - 1], SampleMs);
  Recent := MilliSecondsBetween(Now, FTimes[FCount - 1]) <=
    Max(FSpanMs, Int64(DefaultHistoryHours) * 3600 * 1000);
  Result := True;
end;

procedure TfrmMain.CatchUpToNow;
var
  First: Integer;
  Oldest: TDateTime;
begin
  // Never back-fill more than the generated range
  Oldest := IncMilliSecond(Now, -Max(FSpanMs, Int64(DefaultHistoryHours) * 3600 * 1000));
  if FNextTime < Oldest then
    FNextTime := Oldest;
  First := FCount;
  while FNextTime <= Now do
  begin
    AddSample(FNextTime);
    FNextTime := IncMilliSecond(FNextTime, SampleMs);
  end;
  AppendToFile(First);
end;

{ ---------- view handling ---------- }

function TfrmMain.VisibleAxisCount: Integer;
var
  s: Integer;
begin
  Result := 0;
  for s := 0 to SeriesCount - 1 do
    if FGen[s].Visible then Inc(Result);
end;

{ Left edge of the axis strip of series S, -1 when hidden.
  Axes are placed side by side on the left, set 1 outermost. }
function TfrmMain.AxisLeft(S: Integer): Integer;
var
  i, n: Integer;
begin
  if not FGen[S].Visible then Exit(-1);
  n := 0;
  for i := 0 to S - 1 do
    if FGen[i].Visible then Inc(n);
  Result := 4 + n * AxisWidth;
end;

function TfrmMain.AxisAt(X, Y: Integer): Integer;
var
  s, L: Integer;
  R: TRect;
begin
  Result := -1;
  R := PlotRect;
  if (Y < R.Top - 22) or (Y > R.Bottom) then Exit;
  for s := 0 to SeriesCount - 1 do
  begin
    L := AxisLeft(s);
    if (L >= 0) and (X >= L) and (X < L + AxisWidth) then Exit(s);
  end;
end;

function TfrmMain.OnXAxis(X, Y: Integer): Boolean;
var
  R: TRect;
begin
  R := PlotRect;
  Result := (X >= R.Left) and (X < R.Right) and (Y > R.Bottom) and
    (Y <= R.Bottom + XAxisHeight);
end;

function TfrmMain.PlotRect: TRect;
begin
  Result := Rect(8 + Max(1, VisibleAxisCount) * AxisWidth, 52,
    FPaintBox.Width - 16, FPaintBox.Height - XAxisHeight - 4);
end;

procedure TfrmMain.ClampView;
begin
  FViewCount := EnsureRange(FViewCount, MinViewCount, Max(MinViewCount, FCount));
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
const
  F = 'dd/mm/yyyy hh:nn:ss';
var
  Shown: string;
begin
  if FCount = 0 then
  begin
    FLblStatus.Caption := 'No data';
    Exit;
  end;
  Shown := FormatDateTime(F, FTimes[FViewStart]) + ' - ' +
    FormatDateTime(F, FTimes[Min(FCount - 1, FViewStart + FViewCount - 1)]);
  FLblStatus.Caption := Format('%d samples / set   |   view %s   |   %s',
    [FCount, Shown, ExtractFileName(FFilePath)]);
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
  SyncWindowCombo;
  FPaintBox.Invalidate;
end;

procedure TfrmMain.ShowLatest;
begin
  ClampView;
  ScrollTo(FCount - FViewCount);
end;

{ Select the matching preset, or none after a free wheel zoom }
procedure TfrmMain.SyncWindowCombo;
var
  i, Idx: Integer;
begin
  Idx := -1;
  for i := Low(WindowSeconds) to High(WindowSeconds) do
    if WindowSeconds[i] * SamplesPerSecond = FViewCount then Idx := i;
  if FCmbWindow.ItemIndex <> Idx then
    FCmbWindow.ItemIndex := Idx;
end;

procedure TfrmMain.SetWindowSeconds(Seconds: Integer);
var
  Center: Integer;
begin
  if FChkFollow.Checked then
  begin
    FViewCount := Seconds * SamplesPerSecond;
    ShowLatest;
  end
  else
  begin
    Center := FViewStart + FViewCount div 2;
    FViewCount := Seconds * SamplesPerSecond;
    ScrollTo(Center - FViewCount div 2);
  end;
end;

{ X zoom keeping the time under AnchorX in place }
procedure TfrmMain.ZoomX(Factor: Double; AnchorX: Integer);
var
  R: TRect;
  Frac, Anchor: Double;
  NewCount: Integer;
begin
  R := PlotRect;
  if R.Width <= 0 then Exit;
  Frac := EnsureRange((AnchorX - R.Left) / R.Width, 0, 1);
  Anchor := FViewStart + Frac * (FViewCount - 1);
  NewCount := EnsureRange(Round(FViewCount * Factor), MinViewCount,
    Max(MinViewCount, FCount));
  if NewCount = FViewCount then Exit;
  FViewCount := NewCount;
  ScrollTo(Round(Anchor - Frac * (FViewCount - 1)));
end;

procedure TfrmMain.PushZoom;
var
  Z: TZoomState;
  s: Integer;
begin
  Z.ViewStart := FViewStart;
  Z.ViewCount := FViewCount;
  for s := 0 to SeriesCount - 1 do
    Z.Axis[s] := FAxis[s];
  SetLength(FZoomStack, Length(FZoomStack) + 1);
  FZoomStack[High(FZoomStack)] := Z;
end;

{ Back to the view before the last rectangle zoom; with nothing left to
  undo the default view (all Y axes 0..140, latest 10 minutes) is shown. }
procedure TfrmMain.UndoZoom;
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
  for s := 0 to SeriesCount - 1 do
    FAxis[s] := Z.Axis[s];
  FViewCount := Z.ViewCount;
  ScrollTo(Z.ViewStart);
end;

{ Zoom so that the selected screen rectangle fills the plot:
  time range on X and, for every visible data set, its own Y axis. }
procedure TfrmMain.ZoomToRect(const Sel: TRect);
var
  R: TRect;
  s, I1, I2: Integer;
  VTop, VBottom, Span: Double;
  DoX, DoY: Boolean;
begin
  R := PlotRect;
  DoX := Sel.Width >= 6;
  DoY := Sel.Height >= 6;
  if not (DoX or DoY) then Exit;
  PushZoom;

  if DoY then
    for s := 0 to SeriesCount - 1 do
      if FGen[s].Visible then
      begin
        Span := FAxis[s].Max - FAxis[s].Min;
        VTop := FAxis[s].Min + (R.Bottom - Sel.Top) / R.Height * Span;
        VBottom := FAxis[s].Min + (R.Bottom - Sel.Bottom) / R.Height * Span;
        FAxis[s].Min := VBottom;
        FAxis[s].Max := VTop;
      end;

  if DoX then
  begin
    I1 := FViewStart + Round((Sel.Left - R.Left) / R.Width * (FViewCount - 1));
    I2 := FViewStart + Round((Sel.Right - R.Left) / R.Width * (FViewCount - 1));
    FViewCount := Max(MinViewCount, I2 - I1 + 1);
    // keep the zoomed area still while live data keeps coming in
    FChkFollow.OnChange := nil;
    FChkFollow.Checked := False;
    FChkFollow.OnChange := @ChkFollowChange;
    ScrollTo(I1 + (I2 - I1 + 1 - FViewCount) div 2);
  end
  else
    FPaintBox.Invalidate;
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
  if FCmbWindow.ItemIndex >= 0 then
    SetWindowSeconds(WindowSeconds[FCmbWindow.ItemIndex]);
end;

procedure TfrmMain.ChkFollowChange(Sender: TObject);
begin
  if FChkFollow.Checked then
    ShowLatest;
end;

procedure TfrmMain.PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  A: Integer;
begin
  if FDragging or FSelecting or (FAxisDrag >= 0) then Exit;
  A := AxisAt(X, Y);
  if (Button = mbLeft) and (A >= 0) then
  begin
    // start moving this Y axis up / down
    FAxisDrag := A;
    FActiveAxis := A;
    FAxisDragY := Y;
    FAxisDragMin := FAxis[A].Min;
    FPaintBox.Invalidate;
  end
  else if (Button = mbLeft) and PlotRect.Contains(Point(X, Y)) then
  begin
    // start a zoom rectangle
    FSelecting := True;
    FSelStart := Point(X, Y);
    FSelEnd := FSelStart;
    FPaintBox.Cursor := crCross;
  end
  else if ((Button = mbLeft) and OnXAxis(X, Y)) or
          ((Button = mbRight) and PlotRect.Contains(Point(X, Y))) then
  begin
    // start scrolling in time (left on X axis, right in the plot)
    FDragging := True;
    FDragX := X;
    FDragStart := FViewStart;
    FPaintBox.Cursor := crSizeWE;
    FPaintBox.Invalidate;
  end;
end;

procedure TfrmMain.PaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
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
    // the grabbed value follows the mouse
    Span := FAxis[FAxisDrag].Max - FAxis[FAxisDrag].Min;
    FAxis[FAxisDrag].Min := FAxisDragMin + (Y - FAxisDragY) / Max(1, R.Height) * Span;
    FAxis[FAxisDrag].Max := FAxis[FAxisDrag].Min + Span;
    FPaintBox.Invalidate;
  end
  else if FDragging then
  begin
    if R.Width > 0 then
      ScrollTo(FDragStart - Round((X - FDragX) / R.Width * FViewCount));
  end
  else
  begin
    if AxisAt(X, Y) >= 0 then
      FPaintBox.Cursor := crSizeNS
    else if OnXAxis(X, Y) then
      FPaintBox.Cursor := crSizeWE
    else if R.Contains(Point(X, Y)) then
      FPaintBox.Cursor := crCross
    else
      FPaintBox.Cursor := crDefault;
    FPaintBox.Invalidate;
  end;
end;

procedure TfrmMain.PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Sel, R: TRect;
  Idx: Integer;
begin
  if FSelecting and (Button = mbLeft) then
  begin
    FSelecting := False;
    Sel := Rect(Min(FSelStart.X, FSelEnd.X), Min(FSelStart.Y, FSelEnd.Y),
      Max(FSelStart.X, FSelEnd.X), Max(FSelStart.Y, FSelEnd.Y));
    // a click (no real drag) pins that moment,
    // left-to-right = zoom in, right-to-left = undo the last zoom
    if (Abs(FSelEnd.X - FSelStart.X) <= 3) and (Abs(FSelEnd.Y - FSelStart.Y) <= 3) then
    begin
      R := PlotRect;
      Idx := FViewStart + Round((FSelStart.X - R.Left) / Max(1, R.Width) * (FViewCount - 1));
      if (FCount > 0) and (Idx >= 0) and (Idx < FCount) then
        AddPin(FTimes[Idx], True);
    end
    else if FSelEnd.X < FSelStart.X - 5 then
      UndoZoom
    else
      ZoomToRect(Sel);
    FPaintBox.Invalidate;
  end;
  FDragging := False;
  FAxisDrag := -1;
  PaintBoxMouseMove(Sender, Shift, X, Y);
end;

procedure TfrmMain.PaintBoxMouseLeave(Sender: TObject);
begin
  FHoverX := -1;
  FPaintBox.Invalidate;
end;

procedure TfrmMain.PaintBoxDblClick(Sender: TObject);
var
  A: Integer;
begin
  A := AxisAt(FHoverX, FHoverY);
  if A >= 0 then
  begin
    ResetAxis(A);
    FPaintBox.Invalidate;
  end;
end;

procedure TfrmMain.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  A: Integer;
  P: TPoint;
  R: TRect;
  V, F: Double;
begin
  P := FPaintBox.ScreenToClient(Mouse.CursorPos);
  if not FPaintBox.ClientRect.Contains(P) then Exit;
  Handled := True;
  if WheelDelta > 0 then F := 0.8 else F := 1 / 0.8;

  A := AxisAt(P.X, P.Y);
  if A >= 0 then
  begin
    // Wheel over a Y axis: zoom that axis around the value under the mouse
    R := PlotRect;
    V := FAxis[A].Min + (R.Bottom - P.Y) / Max(1, R.Height) * (FAxis[A].Max - FAxis[A].Min);
    FAxis[A].Min := V - (V - FAxis[A].Min) * F;
    FAxis[A].Max := V + (FAxis[A].Max - V) * F;
    FActiveAxis := A;
    FPaintBox.Invalidate;
  end
  else if ssShift in Shift then
  begin
    // Shift+wheel: scroll in time
    if WheelDelta > 0 then
      ScrollTo(FViewStart - Max(1, FViewCount div 10))
    else
      ScrollTo(FViewStart + Max(1, FViewCount div 10));
  end
  else
    // Wheel: zoom the X axis in/out around the mouse position
    ZoomX(F, P.X);
end;

{ ---------- menu ---------- }

procedure TfrmMain.MnuOpenClick(Sender: TObject);
var
  Recent: Boolean;
  s: Integer;
begin
  FOpenDialog.InitialDir := ExtractFilePath(FFilePath);
  if not FOpenDialog.Execute then Exit;
  FTimer.Enabled := False;
  if not LoadFromFile(FOpenDialog.FileName, Recent) then
  begin
    MessageDlg('No valid data found in' + LineEnding + FOpenDialog.FileName,
      mtError, [mbOK], 0);
    // keep running on the previous file
    if LoadFromFile(FFilePath, Recent) then ;
  end
  else
  begin
    FFilePath := FOpenDialog.FileName;
    for s := 0 to SeriesCount - 1 do
      ResetAxis(s);
    SetLength(FZoomStack, 0);
    // An old file is shown as it is; live generation is switched off so no
    // time gap is appended to it. A recent file continues live.
    FChkRunning.Checked := Recent;
    if Recent then CatchUpToNow;
    SyncDailyFiles;
  end;
  SyncGeneratorPanel;
  RefreshPinGrid;
  FTimer.Enabled := FChkRunning.Checked;
  ShowLatest;
end;

procedure TfrmMain.MnuSaveClick(Sender: TObject);
begin
  try
    SaveToFile(FFilePath);
    FLblStatus.Caption := 'Saved ' + FFilePath;
  except
    on E: Exception do
      MessageDlg('Cannot save file' + LineEnding + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TfrmMain.MnuSaveAsClick(Sender: TObject);
begin
  FSaveDialog.Title := 'Save all data sets as';
  FSaveDialog.InitialDir := ExtractFilePath(FFilePath);
  FSaveDialog.FileName := ExtractFileName(FFilePath);
  if not FSaveDialog.Execute then Exit;
  try
    SaveToFile(FSaveDialog.FileName);
    // live samples are appended to the newly saved file from now on
    FFilePath := FSaveDialog.FileName;
    SyncDailyFiles;   // daily file names follow the main file name
    UpdateStatus;
  except
    on E: Exception do
      MessageDlg('Cannot save file' + LineEnding + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TfrmMain.MnuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmMain.MnuGenPanelClick(Sender: TObject);
begin
  FMnuGenPanel.Checked := not FMnuGenPanel.Checked;
  FGenPanel.Visible := FMnuGenPanel.Checked;
  FSplitter.Visible := FMnuGenPanel.Checked;
  if FSplitter.Visible then
    FSplitter.Left := FGenPanel.Left - FSplitter.Width;
end;

procedure TfrmMain.MnuToolbarClick(Sender: TObject);
begin
  FMnuToolbar.Checked := not FMnuToolbar.Checked;
  FTopPanel.Visible := FMnuToolbar.Checked;
end;

procedure TfrmMain.MnuResetAxesClick(Sender: TObject);
var
  s: Integer;
begin
  for s := 0 to SeriesCount - 1 do
    ResetAxis(s);
  FPaintBox.Invalidate;
end;

procedure TfrmMain.MnuUndoZoomClick(Sender: TObject);
begin
  UndoZoom;
end;

procedure TfrmMain.MnuResetZoomClick(Sender: TObject);
var
  s: Integer;
begin
  SetLength(FZoomStack, 0);
  for s := 0 to SeriesCount - 1 do
    ResetAxis(s);
  FViewCount := WindowSeconds[DefaultWindowIndex] * SamplesPerSecond;
  FChkFollow.Checked := True;
  ShowLatest;
end;

{ ---------- generator panel ---------- }

procedure TfrmMain.GenSpinChange(Sender: TObject);
var
  s: Integer;
  V: Double;
begin
  if FUpdatingGenPanel then Exit;
  s := TFloatSpinEdit(Sender).Tag div 10;
  V := TFloatSpinEdit(Sender).Value;
  case TGenField(TFloatSpinEdit(Sender).Tag mod 10) of
    gfBase: FGen[s].Base := V;
    gfAmplitude: FGen[s].Amplitude := V;
    gfSmooth: FGen[s].Smooth := V;
    gfJitter: FGen[s].Jitter := V;
  end;
end;

procedure TfrmMain.GenVisibleChange(Sender: TObject);
var
  s: Integer;
begin
  if FUpdatingGenPanel then Exit;
  s := TCheckBox(Sender).Tag;
  FGen[s].Visible := TCheckBox(Sender).Checked;
  if not FGen[FActiveAxis].Visible then
    for s := 0 to SeriesCount - 1 do
      if FGen[s].Visible then
      begin
        FActiveAxis := s;
        Break;
      end;
  FPaintBox.Invalidate;
end;

procedure TfrmMain.GenColorChange(Sender: TObject);
var
  C: TColor;
begin
  if FUpdatingGenPanel then Exit;
  C := ColorToRGB(TColorButton(Sender).ButtonColor);
  FGen[TColorButton(Sender).Tag].Color := BGRA(Red(C), Green(C), Blue(C));
  FPaintBox.Invalidate;
end;

{ Rename a data set. ';' is the CSV separator, so it is not allowed. }
procedure TfrmMain.GenNameChange(Sender: TObject);
var
  s: Integer;
  NewName: string;
begin
  if FUpdatingGenPanel then Exit;
  s := TEdit(Sender).Tag;
  NewName := Trim(StringReplace(TEdit(Sender).Text, ';', ',', [rfReplaceAll]));
  if NewName = '' then NewName := 'Set ' + IntToStr(s + 1);
  FGen[s].Name := NewName;
  FSetGroup[s].Caption := ' ' + NewName + ' ';
  RefreshPinGrid;
  FPaintBox.Invalidate;
end;

{ New data type: the set is regenerated with that type over the whole time
  range (the other sets stay), its Y axis is reset and the file rewritten. }
procedure TfrmMain.GenKindChange(Sender: TObject);
var
  s: Integer;
  NewKind: TDataKind;
begin
  if FUpdatingGenPanel then Exit;
  s := TComboBox(Sender).Tag;
  if TComboBox(Sender).ItemIndex < 0 then Exit;
  NewKind := TDataKind(TComboBox(Sender).ItemIndex);
  if NewKind = FGen[s].Kind then Exit;
  Screen.Cursor := crHourGlass;
  try
    FGen[s].Kind := NewKind;
    RegenerateSeries(s);
    SyncDailyFiles;
    RefreshPinGrid;
    ResetAxis(s);
    try
      SaveToFile(FFilePath);
    except
      on E: Exception do
        MessageDlg('Cannot write ' + FFilePath + LineEnding + E.Message, mtError, [mbOK], 0);
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  FPaintBox.Invalidate;
end;

{ New timestamp format: the whole file is rewritten in it, live samples
  are appended in it from now on. }
procedure TfrmMain.TimeFormatChange(Sender: TObject);
begin
  if FUpdatingGenPanel or (FCmbTimeFormat.ItemIndex < 0) then Exit;
  if TTimeFormat(FCmbTimeFormat.ItemIndex) = FTimeFormat then Exit;
  FTimeFormat := TTimeFormat(FCmbTimeFormat.ItemIndex);
  Screen.Cursor := crHourGlass;
  try
    try
      SaveToFile(FFilePath);
      SyncDailyFiles;
      FLblStatus.Caption := 'Timestamps now written as ' +
        Trim(TimeFormatNames[FTimeFormat]) + ' in ' + ExtractFileName(FFilePath);
    except
      on E: Exception do
        MessageDlg('Cannot write ' + FFilePath + LineEnding + E.Message, mtError, [mbOK], 0);
    end;
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.BtnSaveSetClick(Sender: TObject);
var
  s: Integer;
begin
  s := TButton(Sender).Tag;
  FSaveDialog.Title := 'Save data set "' + FGen[s].Name + '"';
  FSaveDialog.InitialDir := ExtractFilePath(FFilePath);
  FSaveDialog.FileName := SafeFileName(FGen[s].Name) + '.csv';
  if not FSaveDialog.Execute then Exit;
  try
    SaveSeriesToFile(s, FSaveDialog.FileName);
    FLblStatus.Caption := 'Saved "' + FGen[s].Name + '" to ' + FSaveDialog.FileName;
  except
    on E: Exception do
      MessageDlg('Cannot save file' + LineEnding + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TfrmMain.ChkRunningChange(Sender: TObject);
begin
  FTimer.Enabled := FChkRunning.Checked;
end;

procedure TfrmMain.BtnLast3hClick(Sender: TObject);
begin
  SetDateTimeSpins(FStartSpins, IncHour(Now, -DefaultHistoryHours));
  SetDateTimeSpins(FEndSpins, Now);
end;

procedure TfrmMain.BtnGenerateClick(Sender: TObject);
var
  TStart, TEnd: TDateTime;
begin
  if not GetDateTimeSpins(FStartSpins, TStart) then
  begin
    MessageDlg('The start time is not a valid date / time.', mtError, [mbOK], 0);
    Exit;
  end;
  if not GetDateTimeSpins(FEndSpins, TEnd) then
  begin
    MessageDlg('The end time is not a valid date / time.', mtError, [mbOK], 0);
    Exit;
  end;
  if TEnd > Now then
    TEnd := Now;
  if TEnd <= TStart then
  begin
    MessageDlg('The end time must be after the start time (and not in the future).',
      mtError, [mbOK], 0);
    Exit;
  end;
  if TEnd - TStart > MaxRangeDays then
  begin
    MessageDlg(Format('The range may be at most %d days.', [MaxRangeDays]),
      mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('Generate new random data' + LineEnding +
    'from ' + FormatDateTime('dd/mm/yyyy hh:nn:ss', TStart) + LineEnding +
    'to     ' + FormatDateTime('dd/mm/yyyy hh:nn:ss', TEnd) + LineEnding +
    'and overwrite ' + FFilePath + ' ?',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  GenerateRange(TStart, TEnd);
  RefreshPinGrid;
  FChkFollow.Checked := True;
  ShowLatest;
end;

procedure TfrmMain.BtnDefaultsClick(Sender: TObject);
var
  s: Integer;
  Saved: array[0..SeriesCount - 1] of TGenerator;
begin
  for s := 0 to SeriesCount - 1 do
    Saved[s] := FGen[s];
  InitGenerators;
  // keep the current random-walk state so the curves continue smoothly;
  // the data type stays too, it belongs to the data already generated
  for s := 0 to SeriesCount - 1 do
  begin
    FGen[s].Value := Saved[s].Value;
    FGen[s].Target := Saved[s].Target;
    FGen[s].BoolState := Saved[s].BoolState;
    FGen[s].Kind := Saved[s].Kind;
  end;
  SyncGeneratorPanel;
  FPaintBox.Invalidate;
end;

{ ---------- pin data panel ---------- }

procedure TfrmMain.BuildPinPanel;
const
  SpinX: array[0..5] of Integer = (160, 208, 256, 326, 374, 422);
  SpinW: array[0..5] of Integer = (46, 46, 62, 46, 46, 46);
  MinV: array[0..5] of Integer = (1, 1, 2000, 0, 0, 0);
  MaxV: array[0..5] of Integer = (31, 12, 2100, 23, 59, 59);
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
  FPinPanel.Height := 160;
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
    FPinSpins[i].Hint := DateTimeCaptions[i];
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
  FPinGrid.ColCount := 2 + SeriesCount;
  FPinGrid.Options := FPinGrid.Options + [goRowSelect, goColSizing] - [goRangeSelect];
  FPinGrid.DefaultRowHeight := 22;
  FPinGrid.ColWidths[0] := 50;
  FPinGrid.ColWidths[1] := 180;
  for i := 0 to SeriesCount - 1 do
    FPinGrid.ColWidths[2 + i] := 170;
  FPinGrid.OnDblClick := @PinGridDblClick;
  FPinGrid.OnKeyDown := @PinGridKeyDown;
  FPinGrid.OnSelectCell := nil;
  FPinGrid.OnSelection := @PinGridSelection;

  SetDateTimeSpins(FPinSpins, Now);
end;

{ Index of the sample nearest to T (times are ascending), -1 without data }
function TfrmMain.FindIndex(T: TDateTime): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  if FCount = 0 then Exit(-1);
  Lo := 0;
  Hi := FCount - 1;
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if FTimes[Mid] < T then Lo := Mid + 1 else Hi := Mid;
  end;
  Result := Lo;
  if (Result > 0) and (Abs(FTimes[Result - 1] - T) < Abs(FTimes[Result] - T)) then
    Dec(Result);
end;

{ Sample index of pin P, -1 when that time is not in the data (any more) }
function TfrmMain.PinIndex(P: Integer): Integer;
begin
  Result := FindIndex(FPins[P]);
  if (Result >= 0) and (Abs(FTimes[Result] - FPins[P]) * SecsPerDay > 1) then
    Result := -1;
end;

function TfrmMain.SelectedPin: Integer;
begin
  Result := -1;
  if (FPinGrid <> nil) and (FPinGrid.Row >= 1) and (FPinGrid.Row <= Length(FPins)) then
    Result := FPinGrid.Row - 1;
end;

{ Pins the sample nearest to T. The pins stay sorted by time (P1 = oldest). }
procedure TfrmMain.AddPin(T: TDateTime; FromChart: Boolean);
var
  Idx, P, i: Integer;
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
  Idx := FindIndex(T);
  T := FTimes[Idx];

  // already pinned -> just select it
  for P := 0 to High(FPins) do
    if PinIndex(P) = Idx then
    begin
      RefreshPinGrid;
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

  SetDateTimeSpins(FPinSpins, T);
  RefreshPinGrid;
  FPinGrid.Row := P + 1;
  FPaintBox.Invalidate;
end;

procedure TfrmMain.RemovePin(P: Integer);
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

{ One row per pin: number, time and the value of each data set }
procedure TfrmMain.RefreshPinGrid;
var
  P, s, Idx: Integer;
begin
  if FPinGrid = nil then Exit;
  FPinGrid.BeginUpdate;
  try
    FPinGrid.RowCount := 1 + Length(FPins);
    FPinGrid.Cells[0, 0] := 'Pin';
    FPinGrid.Cells[1, 0] := 'Time';
    for s := 0 to SeriesCount - 1 do
      FPinGrid.Cells[2 + s, 0] := FGen[s].Name + ' [' + KindNames[FGen[s].Kind] + ']';
    for P := 0 to High(FPins) do
    begin
      Idx := PinIndex(P);
      FPinGrid.Cells[0, P + 1] := 'P' + IntToStr(P + 1);
      FPinGrid.Cells[1, P + 1] := FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FPins[P]);
      for s := 0 to SeriesCount - 1 do
        if Idx >= 0 then
          FPinGrid.Cells[2 + s, P + 1] := DisplayValue(s, FData[s][Idx])
        else
          FPinGrid.Cells[2 + s, P + 1] := '- (no data)';
    end;
  finally
    FPinGrid.EndUpdate;
  end;
end;

procedure TfrmMain.GoToPin(P: Integer);
var
  Idx: Integer;
begin
  if (P < 0) or (P > High(FPins)) then Exit;
  Idx := PinIndex(P);
  if Idx < 0 then Exit;
  ScrollTo(Idx - FViewCount div 2);
end;

procedure TfrmMain.BtnAddPinClick(Sender: TObject);
var
  T: TDateTime;
begin
  if not GetDateTimeSpins(FPinSpins, T) then
  begin
    MessageDlg('The pin time is not a valid date / time.', mtError, [mbOK], 0);
    Exit;
  end;
  AddPin(T, False);
  GoToPin(SelectedPin);
end;

procedure TfrmMain.BtnRemovePinClick(Sender: TObject);
begin
  RemovePin(SelectedPin);
end;

procedure TfrmMain.BtnClearPinsClick(Sender: TObject);
begin
  SetLength(FPins, 0);
  RefreshPinGrid;
  FPaintBox.Invalidate;
end;

procedure TfrmMain.BtnGoToPinClick(Sender: TObject);
begin
  GoToPin(SelectedPin);
end;

procedure TfrmMain.PinGridDblClick(Sender: TObject);
begin
  GoToPin(SelectedPin);
end;

procedure TfrmMain.PinGridKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
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

procedure TfrmMain.PinGridSelection(Sender: TObject; aCol, aRow: Integer);
begin
  // the selected pin is drawn thicker
  FPaintBox.Invalidate;
end;

procedure TfrmMain.MnuPinPanelClick(Sender: TObject);
begin
  FMnuPinPanel.Checked := not FMnuPinPanel.Checked;
  FPinPanel.Visible := FMnuPinPanel.Checked;
  FPinSplitter.Visible := FMnuPinPanel.Checked;
  if FPinSplitter.Visible then
    FPinSplitter.Top := FPinPanel.Top - FPinSplitter.Height;
end;

{ ---------- PNG export ---------- }

procedure TfrmMain.MnuExportPngClick(Sender: TObject);
var
  Bmp: TBGRABitmap;
  FileName: string;
begin
  FPngDialog.InitialDir := ExtractFilePath(FFilePath);
  FPngDialog.FileName := ChangeFileExt(ExtractFileName(FFilePath), '') + '_' +
    FormatDateTime('yyyymmdd_hhnnss', Now) + '.png';
  if not FPngDialog.Execute then Exit;
  FileName := FPngDialog.FileName;
  if not SameText(ExtractFileExt(FileName), '.png') then
    FileName := FileName + '.png';

  // same picture as on screen, without mouse cursor / zoom box / hints
  Bmp := RenderChart(False);
  if Bmp = nil then
  begin
    MessageDlg('The chart is too small to export.', mtError, [mbOK], 0);
    Exit;
  end;
  try
    try
      Bmp.SaveToFileUTF8(FileName);
      FLblStatus.Caption := Format('Chart exported to %s (%d x %d)',
        [FileName, Bmp.Width, Bmp.Height]);
    except
      on E: Exception do
        MessageDlg('Cannot export the chart' + LineEnding + E.Message, mtError, [mbOK], 0);
    end;
  finally
    Bmp.Free;
  end;
end;

procedure TfrmMain.MnuExportSvgClick(Sender: TObject);
var
  P: TSVGChartPainter;
  FileName: string;
  H: Integer;
begin
  if (FPaintBox.Width < 260) or (FPaintBox.Height < 120) then
  begin
    MessageDlg('The chart is too small to export.', mtError, [mbOK], 0);
    Exit;
  end;
  FSvgDialog.InitialDir := ExtractFilePath(FFilePath);
  FSvgDialog.FileName := ChangeFileExt(ExtractFileName(FFilePath), '') + '_' +
    FormatDateTime('yyyymmdd_hhnnss', Now) + '.svg';
  if not FSvgDialog.Execute then Exit;
  FileName := FSvgDialog.FileName;
  if not SameText(ExtractFileExt(FileName), '.svg') then
    FileName := FileName + '.svg';

  // vector version of the same chart; pins and their value table included
  H := FPaintBox.Height + PinTableHeight;
  P := TSVGChartPainter.Create(FPaintBox.Width, H);
  try
    try
      DrawChart(P, FPaintBox.Width, H, False);
      P.SaveToFile(FileName);
      FLblStatus.Caption := Format('Vector chart exported to %s (%d pin(s))',
        [FileName, Length(FPins)]);
    except
      on E: Exception do
        MessageDlg('Cannot export the chart' + LineEnding + E.Message, mtError, [mbOK], 0);
    end;
  finally
    P.Free;
  end;
end;

{ ---------- CSV export, one file per day ---------- }

procedure TfrmMain.MnuExportDailyClick(Sender: TObject);
var
  Files: Integer;
  Names: string;
begin
  if FCount = 0 then Exit;
  FDayDirDialog.InitialDir := FDailyDir;
  if not FDayDirDialog.Execute then Exit;
  Screen.Cursor := crHourGlass;
  try
    try
      Files := WriteDailyFiles(FDayDirDialog.FileName, Names);
    except
      on E: Exception do
      begin
        MessageDlg('Cannot write the daily files' + LineEnding + E.Message, mtError, [mbOK], 0);
        Exit;
      end;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  MessageDlg(Format('%d file(s) written to %s:', [Files, FDayDirDialog.FileName]) +
    LineEnding + LineEnding + Names, mtInformation, [mbOK], 0);
end;

{ ---------- line style ---------- }

procedure TfrmMain.GenLineStyleChange(Sender: TObject);
var
  Idx: Integer;
begin
  if FUpdatingGenPanel then Exit;
  Idx := TComboBox(Sender).ItemIndex;
  if (Idx < Low(LineStyles)) or (Idx > High(LineStyles)) then Exit;
  FGen[TComboBox(Sender).Tag].LineStyle := LineStyles[Idx];
  FPaintBox.Invalidate;
end;

procedure TfrmMain.GenLineWidthChange(Sender: TObject);
begin
  if FUpdatingGenPanel then Exit;
  FGen[TFloatSpinEdit(Sender).Tag].LineWidth := TFloatSpinEdit(Sender).Value;
  FPaintBox.Invalidate;
end;

{ ---------- drawing ---------- }

const
  ChartBackColor: TBGRAPixel = (blue: 32; green: 26; red: 24; alpha: 255);
  PinColor: TBGRAPixel = (blue: 90; green: 220; red: 255; alpha: 255);
  PinRowHeight = 18;

{ Height of the pin value table added under an exported chart }
function TfrmMain.PinTableHeight: Integer;
begin
  if Length(FPins) = 0 then
    Result := 0
  else
    Result := 14 + (Length(FPins) + 1) * PinRowHeight;
end;

{ Raster chart (screen / PNG). Interactive = False: export picture without
  mouse cursor, zoom box or hints, plus the pin table when there are pins. }
function TfrmMain.RenderChart(Interactive: Boolean): TBGRABitmap;
var
  H: Integer;
  P: TBGRAChartPainter;
begin
  Result := nil;
  if (FPaintBox.Width < 260) or (FPaintBox.Height < 120) then Exit;
  H := FPaintBox.Height;
  if not Interactive then Inc(H, PinTableHeight);
  Result := TBGRABitmap.Create(FPaintBox.Width, H, ChartBackColor);
  P := TBGRAChartPainter.Create(Result);
  try
    DrawChart(P, FPaintBox.Width, H, Interactive);
  finally
    P.Free;
  end;
end;

{ The whole chart, on any painter (BGRABitmap or SVG). The chart itself
  uses the paint box size; W x H is the full picture. }
procedure TfrmMain.DrawChart(P: TChartPainter; W, H: Integer; Interactive: Boolean);
var
  R: TRect;
  PW, PH, s, i, pn, px, Step, LastIdx, A, B, Idx, AxL, AxX, NTicks, Y0: Integer;
  SpanSec, T0Sec, TSec, YStep, V, Span: Double;
  Pts: array of TPointF;
  NPts: Integer;
  MinV, MaxV: Double;
  MinFirst: Boolean;
  Fmt, Txt: string;
  X, Yf, TW, LegendX: Single;
  C, Dim: TBGRAPixel;
  ColX: array[0..SeriesCount + 1] of Single;

  function YOf(S: Integer; Value: Double): Single;
  begin
    Result := R.Bottom - (Value - FAxis[S].Min) / (FAxis[S].Max - FAxis[S].Min) * PH;
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
  R := PlotRect;
  PW := R.Width;
  PH := R.Height;
  if (PW < 20) or (PH < 20) then Exit;

  P.FillRect(0, 0, W, H, ChartBackColor);
  P.FillRect(R.Left, R.Top, R.Right, R.Bottom, BGRA(16, 18, 22));
  NTicks := Max(2, PH div 40);

  // X axis strip (drag = scroll in time), highlighted on hover / drag
  if Interactive and (FDragging or OnXAxis(FHoverX, FHoverY)) then
    P.FillRect(R.Left, R.Bottom + 1, R.Right, R.Bottom + XAxisHeight + 1,
      BGRA(255, 255, 255, 22));

  // Separate Y axes, side by side on the left
  for s := 0 to SeriesCount - 1 do
  begin
    AxL := AxisLeft(s);
    if AxL < 0 then Continue;
    C := FGen[s].Color;
    Dim := BGRA(C.red, C.green, C.blue, 150);
    AxX := AxL + AxisWidth - 6;
    Span := FAxis[s].Max - FAxis[s].Min;
    YStep := NiceStep(Span / NTicks);
    if FGen[s].Kind in [dkByte, dkInteger] then
      YStep := Max(1, YStep);   // whole numbers only
    if FGen[s].Kind = dkBoolean then
      YStep := 1;               // just FALSE (0) and TRUE (1)

    if Interactive and ((s = FActiveAxis) or (s = FAxisDrag)) then
      P.FillRect(AxL, R.Top - 22, AxL + AxisWidth - 2, R.Bottom + 1,
        BGRA(C.red, C.green, C.blue, 28));

    P.VLine(AxX, R.Top, R.Bottom, C);
    P.Text(AxL + (AxisWidth - 4) / 2, R.Top - 20, 'Y' + IntToStr(s + 1), C, taCenter);

    V := Ceil(FAxis[s].Min / YStep) * YStep;
    while V <= FAxis[s].Max + YStep * 1e-6 do
    begin
      if (FGen[s].Kind = dkBoolean) and ((V < 0) or (V > 1)) then
      begin
        V := V + YStep;
        Continue;
      end;
      Yf := YOf(s, V);
      P.HLine(AxX - 4, AxX, Round(Yf), C);
      if FGen[s].Kind = dkBoolean then
        Txt := DisplayValue(s, V)
      else
        Txt := FormatAxisValue(V, YStep);
      P.Text(AxX - 6, Yf - 8, Txt, Dim, taRightJustify);
      // grid lines of the active axis
      if s = FActiveAxis then
        P.HLine(R.Left, R.Right - 1, Round(Yf), BGRA(C.red, C.green, C.blue, 40));
      V := V + YStep;
    end;
  end;

  if FCount > 0 then
  begin
    LastIdx := Min(FCount - 1, FViewStart + FViewCount - 1);

    // X grid (time)
    SpanSec := (FViewCount - 1) / SamplesPerSecond;
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
    T0Sec := FTimes[FViewStart] * SecsPerDay;
    TSec := Ceil(T0Sec / Step) * Step;
    while TSec <= T0Sec + SpanSec do
    begin
      X := XOf(FViewStart + (TSec - T0Sec) * SamplesPerSecond);
      P.VLine(Round(X), R.Top, R.Bottom - 1, BGRA(50, 54, 62));
      P.VLine(Round(X), R.Bottom, R.Bottom + 4, BGRA(130, 130, 140));
      P.Text(X, R.Bottom + 6, FormatDateTime(Fmt, TSec / SecsPerDay),
        BGRA(170, 170, 180), taCenter);
      TSec := TSec + Step;
    end;

    // Series, each on its own axis, with its own line style and width
    P.Clip(R);
    for s := 0 to SeriesCount - 1 do
    begin
      if not FGen[s].Visible then Continue;
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
            AddPt(R.Left + px + 0.5, YOf(s, MinV));
            AddPt(R.Left + px + 0.5, YOf(s, MaxV));
          end
          else
          begin
            AddPt(R.Left + px + 0.5, YOf(s, MaxV));
            AddPt(R.Left + px + 0.5, YOf(s, MinV));
          end;
        end;
      end
      else
        for i := FViewStart to LastIdx do
        begin
          // Boolean: square steps, the value holds until the next sample
          if (FGen[s].Kind = dkBoolean) and (i > FViewStart) and
             (FData[s][i] <> FData[s][i - 1]) then
            AddPt(XOf(i), YOf(s, FData[s][i - 1]));
          AddPt(XOf(i), YOf(s, FData[s][i]));
        end;
      SetLength(Pts, NPts);
      P.Polyline(Pts, FGen[s].Color, FGen[s].LineWidth, FGen[s].LineStyle);
    end;

    // Pinned times: dashed line, label and the value of every set
    for pn := 0 to High(FPins) do
    begin
      Idx := PinIndex(pn);
      if (Idx < FViewStart) or (Idx > LastIdx) then Continue;
      X := XOf(Idx);
      if Interactive and (pn = SelectedPin) then TW := 2.2 else TW := 1.2;
      P.Line(X, R.Top, X, R.Bottom, PinColor, TW, psDash);
      Txt := 'P' + IntToStr(pn + 1);
      TW := P.TextWidth(Txt);
      P.RoundRect(X - TW / 2 - 4, R.Top + 2, X + TW / 2 + 4, R.Top + 19, 4, PinColor);
      P.Text(X, R.Top + 3, Txt, BGRA(20, 20, 20), taCenter);
      for s := 0 to SeriesCount - 1 do
        if FGen[s].Visible then
        begin
          Yf := YOf(s, FData[s][Idx]);
          P.Circle(X, Yf, 4.2, FGen[s].Color, PinColor, 1.2);
          P.Text(X + 7, Yf - 17, DisplayValue(s, FData[s][Idx]), FGen[s].Color);
        end;
    end;

    // Hover cursor with values
    if Interactive and (FHoverX >= R.Left) and (FHoverX < R.Right) and
       (FHoverY >= R.Top) and (FHoverY <= R.Bottom) and not FDragging and
       not FSelecting and (FAxisDrag < 0) then
    begin
      Idx := FViewStart + Round((FHoverX - R.Left) / PW * (FViewCount - 1));
      if (Idx >= 0) and (Idx < FCount) then
      begin
        X := XOf(Idx);
        P.Line(X, R.Top, X, R.Bottom, BGRA(255, 255, 255, 110), 1);
        for s := 0 to SeriesCount - 1 do
          if FGen[s].Visible then
            P.Circle(X, YOf(s, FData[s][Idx]), 3.5, FGen[s].Color, BGRAPixelTransparent, 0);
        P.NoClip;
        LegendX := R.Right - 4;
        for s := SeriesCount - 1 downto 0 do
          if FGen[s].Visible then
          begin
            Txt := DisplayValue(s, FData[s][Idx]);
            P.Text(LegendX, 28, Txt, FGen[s].Color, taRightJustify);
            LegendX := LegendX - P.TextWidth(Txt) - 16;
          end;
        P.Text(LegendX, 28, FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FTimes[Idx]),
          BGRA(240, 240, 240), taRightJustify);
      end;
    end
    else
    begin
      P.NoClip;
      if Interactive then
        P.Text(R.Left, 28, 'Click = pin time, drag box = zoom (right-to-left = undo), ' +
          'wheel = zoom time, drag X axis / right-drag = scroll, drag Y axis = move',
          BGRA(120, 124, 132))
      else
        P.Text(R.Left, 28, FormatDateTime('dd/mm/yyyy hh:nn:ss', FTimes[FViewStart]) +
          '  -  ' + FormatDateTime('dd/mm/yyyy hh:nn:ss', FTimes[LastIdx]) +
          '     (' + ExtractFileName(FFilePath) + ')', BGRA(170, 174, 182));
    end;
    P.NoClip;
  end;

  // Zoom rectangle
  if Interactive and FSelecting and ((Abs(FSelEnd.X - FSelStart.X) > 2) or
     (Abs(FSelEnd.Y - FSelStart.Y) > 2)) then
  begin
    if FSelEnd.X < FSelStart.X - 5 then
      C := BGRA(255, 120, 120)   // backwards = undo zoom
    else
      C := BGRA(120, 180, 255);
    P.FillRect(Min(FSelStart.X, FSelEnd.X), Min(FSelStart.Y, FSelEnd.Y),
      Max(FSelStart.X, FSelEnd.X), Max(FSelStart.Y, FSelEnd.Y),
      BGRA(C.red, C.green, C.blue, 40));
    P.Frame(Min(FSelStart.X, FSelEnd.X), Min(FSelStart.Y, FSelEnd.Y),
      Max(FSelStart.X, FSelEnd.X), Max(FSelStart.Y, FSelEnd.Y), C, 1.01);
    if FSelEnd.X < FSelStart.X - 5 then
      P.Text(Min(FSelStart.X, FSelEnd.X) + 4, Min(FSelStart.Y, FSelEnd.Y) + 2,
        'Undo zoom', C);
  end;

  // Legend with a sample of each line style
  LegendX := R.Left;
  for s := 0 to SeriesCount - 1 do
  begin
    if FGen[s].Visible then C := FGen[s].Color else C := BGRA(90, 90, 95);
    P.Line(LegendX, 15, LegendX + 22, 15, C, Max(1.5, FGen[s].LineWidth), FGen[s].LineStyle);
    Txt := 'Y' + IntToStr(s + 1) + ': ' + FGen[s].Name;
    P.Text(LegendX + 28, 7, Txt, BGRA(220, 220, 225));
    LegendX := LegendX + 28 + P.TextWidth(Txt) + 28;
  end;

  P.Frame(R.Left, R.Top, R.Right, R.Bottom, BGRA(90, 95, 105));

  // Export only: table of the pinned values under the chart
  if not Interactive and (Length(FPins) > 0) then
  begin
    Y0 := FPaintBox.Height + 6;
    ColX[0] := R.Left;
    ColX[1] := R.Left + 44;
    ColX[2] := R.Left + 230;
    for s := 1 to SeriesCount - 1 do
      ColX[2 + s] := ColX[1 + s] + Max(140, (R.Right - ColX[2]) / SeriesCount);
    P.HLine(R.Left, R.Right, Y0 - 2, BGRA(90, 95, 105));
    P.Text(ColX[0], Y0, 'Pin', BGRA(200, 200, 205));
    P.Text(ColX[1], Y0, 'Time', BGRA(200, 200, 205));
    for s := 0 to SeriesCount - 1 do
      P.Text(ColX[2 + s], Y0, FGen[s].Name, FGen[s].Color);
    for pn := 0 to High(FPins) do
    begin
      Yf := Y0 + (pn + 1) * PinRowHeight;
      Idx := PinIndex(pn);
      P.Text(ColX[0], Yf, 'P' + IntToStr(pn + 1), PinColor);
      P.Text(ColX[1], Yf, FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FPins[pn]),
        BGRA(220, 220, 225));
      for s := 0 to SeriesCount - 1 do
        if Idx >= 0 then
          P.Text(ColX[2 + s], Yf, DisplayValue(s, FData[s][Idx]), FGen[s].Color)
        else
          P.Text(ColX[2 + s], Yf, '-', BGRA(150, 150, 150));
    end;
  end;
end;

procedure TfrmMain.PaintBoxPaint(Sender: TObject);
var
  Bmp: TBGRABitmap;
begin
  Bmp := RenderChart(True);
  if Bmp = nil then Exit;
  try
    Bmp.Draw(FPaintBox.Canvas, 0, 0, True);
  finally
    Bmp.Free;
  end;
end;

end.
