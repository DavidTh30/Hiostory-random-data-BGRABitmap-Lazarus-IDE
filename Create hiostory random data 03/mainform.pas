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
  StdCtrls, Menus, Dialogs, Spin, BGRABitmap, BGRABitmapTypes;

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
  { Mean-reverting random walk followed by a low-pass filter.
    Smooth = filter factor (small = smoother), Jitter = raw noise. }
  TGenerator = record
    Name: string;
    Base, Amplitude, Smooth, Jitter: Double;
    Color: TBGRAPixel;
    Visible: Boolean;
    Target, Value: Double;
  end;

  { Independent Y axis of one data set }
  TAxis = record
    Min, Max: Double;
  end;

  { Generator panel field ids (stored in the control's Tag) }
  TGenField = (gfBase, gfAmplitude, gfSmooth, gfJitter);

  { Day, Month, Year, Hour, Minute, Second }
  TDateTimeSpins = array[0..5] of TSpinEdit;

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
    FFS: TFormatSettings;
    FFilePath: string;

    procedure BuildMenu;
    procedure BuildUI;
    procedure BuildGeneratorPanel;
    function BuildDateTimeRow(AParent: TWinControl; const ACaption: string;
      ATop: Integer; out Spins: TDateTimeSpins): Integer;
    procedure SetDateTimeSpins(const Spins: TDateTimeSpins; T: TDateTime);
    function GetDateTimeSpins(const Spins: TDateTimeSpins; out T: TDateTime): Boolean;
    procedure SyncGeneratorPanel;
    procedure InitGenerators;
    procedure ResetAxis(S: Integer);
    function SpanSamples: Integer;
    function NextValue(var G: TGenerator): Double;
    procedure ClearData;
    procedure AddSample(T: TDateTime);
    function SampleLine(Index: Integer): string;
    function HeaderLine: string;
    procedure AppendToFile(FromIndex: Integer);
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
    // generator panel handlers
    procedure GenSpinChange(Sender: TObject);
    procedure GenVisibleChange(Sender: TObject);
    procedure GenColorChange(Sender: TObject);
    procedure GenNameChange(Sender: TObject);
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
    CatchUpToNow
  else
    GenerateRange(IncHour(Now, -DefaultHistoryHours), Now);

  SyncGeneratorPanel;
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
  AddItem(MFile, 'E&xit', @MnuExitClick, ShortCut(Ord('Q'), [ssCtrl]));

  MPanel := TMenuItem.Create(FMainMenu);
  MPanel.Caption := '&Panel';
  FMainMenu.Items.Add(MPanel);
  FMnuGenPanel := AddItem(MPanel, 'Random data &generator', @MnuGenPanelClick,
    ShortCut(Ord('G'), [ssCtrl]));
  FMnuGenPanel.Checked := True;
  FMnuToolbar := AddItem(MPanel, '&Toolbar', @MnuToolbarClick);
  FMnuToolbar.Checked := True;
  AddItem(MPanel, '-', nil);
  Item := AddItem(MPanel, '&Reset Y axes', @MnuResetAxesClick, ShortCut(Ord('R'), [ssCtrl]));
  Item.Hint := 'Reset all Y axes to 0..' + IntToStr(YAxisMax);

  FOpenDialog := TOpenDialog.Create(Self);
  FOpenDialog.Filter := FileFilter;
  FOpenDialog.DefaultExt := 'csv';
  FOpenDialog.Options := FOpenDialog.Options + [ofFileMustExist];

  FSaveDialog := TSaveDialog.Create(Self);
  FSaveDialog.Filter := FileFilter;
  FSaveDialog.DefaultExt := 'csv';
  FSaveDialog.Options := FSaveDialog.Options + [ofOverwritePrompt];
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
  FieldMin: array[TGenField] of Double = (0, 0, 0.005, 0);
  FieldMax: array[TGenField] of Double = (YAxisMax, 70, 1, 20);
  FieldInc: array[TGenField] of Double = (1, 1, 0.01, 0.1);
  FieldDec: array[TGenField] of Integer = (1, 1, 3, 2);
var
  Grp: TGroupBox;
  Lbl: TLabel;
  Btn: TButton;
  s, Y, YY: Integer;
  f: TGenField;
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

  Grp.SetBounds(6, 4, 222, YY + 34 + 30 + 28);
  Y := Grp.Top + Grp.Height + 8;

  // --- one group per data set ---
  for s := 0 to SeriesCount - 1 do
  begin
    Grp := TGroupBox.Create(Self);
    Grp.Parent := FGenPanel;
    Grp.SetBounds(6, Y, 222, 314);
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

    FChkVisible[s] := TCheckBox.Create(Self);
    FChkVisible[s].Parent := Grp;
    FChkVisible[s].SetBounds(10, 40, 80, 20);
    FChkVisible[s].Caption := 'Visible';
    FChkVisible[s].Tag := s;
    FChkVisible[s].OnChange := @GenVisibleChange;

    FColorBtn[s] := TColorButton.Create(Self);
    FColorBtn[s].Parent := Grp;
    FColorBtn[s].SetBounds(110, 36, 98, 26);
    FColorBtn[s].Caption := 'Color';
    FColorBtn[s].Tag := s;
    FColorBtn[s].OnColorChanged := @GenColorChange;

    Btn := TButton.Create(Self);
    Btn.Parent := Grp;
    Btn.SetBounds(10, 68, 198, 26);
    Btn.Caption := 'Save this data set...';
    Btn.Tag := s;
    Btn.OnClick := @BtnSaveSetClick;

    YY := 100;
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
  s: Integer;
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
    end;
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
      Base := ABase;
      Amplitude := AAmp;
      Smooth := ASmooth;
      Jitter := AJitter;
      Color := AColor;
      Visible := True;
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
  FAxis[S].Min := 0;
  FAxis[S].Max := YAxisMax;
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
    NewCap := Max(SpanSamples + 1024, Length(FTimes) * 2);
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

function TfrmMain.HeaderLine: string;
var
  s: Integer;
begin
  Result := 'Time';
  for s := 0 to SeriesCount - 1 do
    Result := Result + ';' + FGen[s].Name;
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
    begin
      F := TFileStream.Create(FFilePath, fmCreate);
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

{ Writes one data set: "Time;<name>" }
procedure TfrmMain.SaveSeriesToFile(S: Integer; const APath: string);
var
  SL: TStringList;
  i: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Capacity := FCount + 1;
    SL.Add('Time;' + FGen[S].Name);
    for i := 0 to FCount - 1 do
      SL.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', FTimes[i]) + ';' +
        FormatFloat('0.000', FData[S][i], FFS));
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

{ New random data from AStart to AEnd (500 ms steps), saved to FFilePath.
  When AEnd is "now", live generation continues afterwards. }
procedure TfrmMain.GenerateRange(AStart, AEnd: TDateTime);
var
  i, N, s: Integer;
  Live: Boolean;
begin
  if AEnd > Now then AEnd := Now;
  Live := MilliSecondsBetween(Now, AEnd) <= 5000;
  FSpanMs := Max(Int64(SampleMs), MilliSecondsBetween(AEnd, AStart));
  N := SpanSamples;

  Screen.Cursor := crHourGlass;
  try
    ClearData;
    for s := 0 to SeriesCount - 1 do
    begin
      FGen[s].Target := FGen[s].Base;
      FGen[s].Value := FGen[s].Base;
    end;
    for i := 0 to N - 1 do
      AddSample(IncMilliSecond(AStart, Int64(i) * SampleMs));
    FNextTime := IncMilliSecond(FTimes[FCount - 1], SampleMs);
    try
      SaveToFile(FFilePath);
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
  live generation can simply continue after it. Data set names are taken
  from the header line. }
function TfrmMain.LoadFromFile(const APath: string; out Recent: Boolean): Boolean;
var
  SL, Parts: TStringList;
  i, s, NewCap: Integer;
  T: TDateTime;
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
        // header: data set names
        for s := 0 to SeriesCount - 1 do
          if Trim(Parts[s + 1]) <> '' then
            FGen[s].Name := Trim(Parts[s + 1]);
        Continue;
      end;
      try
        T := ScanDateTime('yyyy-mm-dd hh:nn:ss.zzz', Parts[0]);
        FTimes[FCount] := T;
        for s := 0 to SeriesCount - 1 do
          FData[s][FCount] := StrToFloat(Parts[s + 1], FFS);
        Inc(FCount);
      except
        // malformed line
      end;
    end;
  finally
    Parts.Free;
    SL.Free;
  end;

  if FCount = 0 then Exit;

  // Continue the random walks from the last stored values
  for s := 0 to SeriesCount - 1 do
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
  if Button <> mbLeft then Exit;
  A := AxisAt(X, Y);
  if A >= 0 then
  begin
    // start moving this Y axis up / down
    FAxisDrag := A;
    FActiveAxis := A;
    FAxisDragY := Y;
    FAxisDragMin := FAxis[A].Min;
    FPaintBox.Invalidate;
  end
  else if OnXAxis(X, Y) or PlotRect.Contains(Point(X, Y)) then
  begin
    // start scrolling in time (X axis or plot area)
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
  if FAxisDrag >= 0 then
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
    else
      FPaintBox.Cursor := crDefault;
    FPaintBox.Invalidate;
  end;
end;

procedure TfrmMain.PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
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
    // An old file is shown as it is; live generation is switched off so no
    // time gap is appended to it. A recent file continues live.
    FChkRunning.Checked := Recent;
    if Recent then CatchUpToNow;
  end;
  SyncGeneratorPanel;
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
  FPaintBox.Invalidate;
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
  // keep the current random-walk state so the curves continue smoothly
  for s := 0 to SeriesCount - 1 do
  begin
    FGen[s].Value := Saved[s].Value;
    FGen[s].Target := Saved[s].Target;
  end;
  SyncGeneratorPanel;
  FPaintBox.Invalidate;
end;

{ ---------- drawing ---------- }

procedure TfrmMain.PaintBoxPaint(Sender: TObject);
const
  BackColor: TBGRAPixel = (blue: 32; green: 26; red: 24; alpha: 255);
var
  Bmp: TBGRABitmap;
  R: TRect;
  PW, PH, s, i, px, Step, LastIdx, A, B, Idx, LegendX, AxL, AxX, NTicks: Integer;
  SpanSec, T0Sec, TSec, YStep, V, Span: Double;
  Pts: array of TPointF;
  NPts: Integer;
  MinV, MaxV: Double;
  MinFirst: Boolean;
  Fmt, Txt: string;
  X, Yf: Single;
  C, Dim: TBGRAPixel;

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
  if (FPaintBox.Width < 260) or (FPaintBox.Height < 120) then Exit;
  Bmp := TBGRABitmap.Create(FPaintBox.Width, FPaintBox.Height, BackColor);
  try
    Bmp.FontName := 'Segoe UI';
    Bmp.FontHeight := 13;
    Bmp.FontQuality := fqSystemClearType;
    R := PlotRect;
    PW := R.Width;
    PH := R.Height;
    if (PW < 20) or (PH < 20) then Exit;
    Bmp.FillRect(R.Left, R.Top, R.Right, R.Bottom, BGRA(16, 18, 22), dmSet);
    NTicks := Max(2, PH div 40);

    // X axis strip (drag = scroll in time), highlighted on hover / drag
    if FDragging or OnXAxis(FHoverX, FHoverY) then
      Bmp.FillRect(R.Left, R.Bottom + 1, R.Right, R.Bottom + XAxisHeight + 1,
        BGRA(255, 255, 255, 22), dmDrawWithTransparency);

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

      if (s = FActiveAxis) or (s = FAxisDrag) then
        Bmp.FillRect(AxL, R.Top - 22, AxL + AxisWidth - 2, R.Bottom + 1,
          BGRA(C.red, C.green, C.blue, 28), dmDrawWithTransparency);

      Bmp.DrawVertLine(AxX, R.Top, R.Bottom, C);
      Bmp.TextOut(AxL + (AxisWidth - 4) / 2, R.Top - 20, 'Y' + IntToStr(s + 1), C, taCenter);

      V := Ceil(FAxis[s].Min / YStep) * YStep;
      while V <= FAxis[s].Max + YStep * 1e-6 do
      begin
        Yf := YOf(s, V);
        Bmp.DrawHorizLine(AxX - 4, Round(Yf), AxX, C);
        Bmp.TextOut(AxX - 6, Yf - 8, FormatAxisValue(V, YStep), Dim, taRightJustify);
        // grid lines of the active axis
        if s = FActiveAxis then
          Bmp.DrawHorizLine(R.Left, Round(Yf), R.Right - 1, BGRA(C.red, C.green, C.blue, 40));
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
        Bmp.DrawVertLine(Round(X), R.Top, R.Bottom - 1, BGRA(50, 54, 62));
        Bmp.DrawVertLine(Round(X), R.Bottom, R.Bottom + 4, BGRA(130, 130, 140));
        Bmp.TextOut(X, R.Bottom + 6, FormatDateTime(Fmt, TSec / SecsPerDay),
          BGRA(170, 170, 180), taCenter);
        TSec := TSec + Step;
      end;

      // Series, each on its own axis
      Bmp.ClipRect := R;
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
            AddPt(XOf(i), YOf(s, FData[s][i]));
        SetLength(Pts, NPts);
        if NPts > 1 then
          Bmp.DrawPolyLineAntialias(Pts, FGen[s].Color, 1.5);
      end;

      // Hover cursor with values
      if (FHoverX >= R.Left) and (FHoverX < R.Right) and (FHoverY >= R.Top) and
         (FHoverY <= R.Bottom) and not FDragging and (FAxisDrag < 0) then
      begin
        Idx := FViewStart + Round((FHoverX - R.Left) / PW * (FViewCount - 1));
        if (Idx >= 0) and (Idx < FCount) then
        begin
          X := XOf(Idx);
          Bmp.DrawLineAntialias(X, R.Top, X, R.Bottom, BGRA(255, 255, 255, 110), 1);
          for s := 0 to SeriesCount - 1 do
            if FGen[s].Visible then
              Bmp.FillEllipseAntialias(X, YOf(s, FData[s][Idx]), 3.5, 3.5, FGen[s].Color);
          Bmp.NoClip;
          LegendX := R.Right - 4;
          for s := SeriesCount - 1 downto 0 do
            if FGen[s].Visible then
            begin
              Txt := FormatFloat('0.00', FData[s][Idx]);
              Bmp.TextOut(LegendX, 28, Txt, FGen[s].Color, taRightJustify);
              Dec(LegendX, Bmp.TextSize(Txt).cx + 16);
            end;
          Bmp.TextOut(LegendX, 28, FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', FTimes[Idx]),
            BGRA(240, 240, 240), taRightJustify);
        end;
      end
      else
      begin
        Bmp.NoClip;
        Bmp.TextOut(R.Left, 28, 'Wheel = zoom time, drag X axis = scroll time, ' +
          'drag Y axis = move, wheel on Y axis = zoom, double-click Y axis = reset',
          BGRA(120, 124, 132));
      end;
      Bmp.NoClip;
    end;

    // Legend
    LegendX := R.Left;
    for s := 0 to SeriesCount - 1 do
    begin
      if FGen[s].Visible then C := FGen[s].Color else C := BGRA(90, 90, 95);
      Bmp.FillRect(LegendX, 13, LegendX + 18, 17, C, dmSet);
      Txt := 'Y' + IntToStr(s + 1) + ': ' + FGen[s].Name;
      Bmp.TextOut(LegendX + 24, 7, Txt, BGRA(220, 220, 225));
      Inc(LegendX, 24 + Bmp.TextSize(Txt).cx + 28);
    end;

    Bmp.Rectangle(R.Left, R.Top, R.Right, R.Bottom, BGRA(90, 95, 105), dmSet);
    Bmp.Draw(FPaintBox.Canvas, 0, 0, True);
  finally
    Bmp.Free;
  end;
end;

end.
