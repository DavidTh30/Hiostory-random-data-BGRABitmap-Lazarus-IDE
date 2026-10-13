unit ViewerForm;

{
  History chart viewer
  --------------------
  Reads the daily CSV files written by HistoryRandomData
  (<folder>\<prefix>_yyyy-mm-dd.csv, header "Time;Name [Type];...").

  * At start only the newest day is read and the chart shows the last
    3 hours. When the view gets close to the oldest loaded sample (scrolling
    back), the previous day file is read and put in front of the data -
    days are only loaded when they are needed.
  * The X axis is real time; gaps in the data (generator not running)
    break the lines instead of joining them.
  * "Follow live": new lines appended to today's file are read every
    second, a new day file is picked up after midnight.
  * Every data set has its own Y axis: drag = move, wheel = zoom,
    double-click = auto range.
  * Time: wheel = zoom, right drag in the chart / left drag on the time
    axis / scrollbar / Shift+wheel = scroll.
  * Left drag in the chart = zoom box (right-to-left = undo zoom).
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DateUtils, StrUtils, Forms, Controls, Graphics,
  ExtCtrls, StdCtrls, Menus, Dialogs, LCLType, BGRABitmap, BGRABitmapTypes,
  ChartPainter, DataGridPanel, ChartFast;

const
  MaxSeries = 8;
  GapSeconds = 3.0;           // samples further apart than this are not joined
  DefaultSpanHours = 3;
  AxisWidth = 58;
  XAxisHeight = 26;
  MinSpanSeconds = 10;

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
    AxisUser: Boolean;        // moved / zoomed by the user -> no auto range
  end;

  { view before a zoom-box zoom, for undo }
  TZoomState = record
    ViewEnd, ViewSpan: TDateTime;
    Follow: Boolean;
    Series: array[0..MaxSeries - 1] of TSeriesInfo;
  end;

  { One daily file; Day = Trunc(date) }
  TDayFile = record
    Day: Integer;
    FileName: string;
  end;

  { TfrmViewer }

  TfrmViewer = class(TForm)
    procedure FormCreate(Sender: TObject);
  private
    // UI
    FMainMenu: TMainMenu;
    FMnuFollow: TMenuItem;
    FMnuSeries: TMenuItem;
    FDirDialog: TSelectDirectoryDialog;
    FTopPanel: TPanel;
    FCmbWindow: TComboBox;
    FChkFollow: TCheckBox;
    FBtnOlder: TButton;
    FLblFolder, FLblStatus: TLabel;
    FPaintBox: TPaintBox;
    FScrollBar: TScrollBar;
    FTimer: TTimer;

    // files
    FDir, FPrefix: string;
    FDays: array of TDayFile;      // available days, ascending
    FFirstLoadedDay, FLastLoadedDay: Integer;  // -1 = nothing loaded
    FTailPos: Int64;               // bytes of the newest day file already read
    FTailCheck: string;            // last line read, to detect a rewritten file
    FTick: Integer;

    // data (ascending time)
    FSeriesCount: Integer;
    FSeries: array[0..MaxSeries - 1] of TSeriesInfo;
    FTimes: TTimeArray;
    FData: TValueArrays;
    FCount: Integer;

    // view
    FViewEnd, FViewSpan: TDateTime;
    FUpdatingScroll: Boolean;
    FHoverX, FHoverY: Integer;
    FDragging: Boolean;
    FDragX: Integer;
    FDragEnd: TDateTime;
    FAxisDrag, FAxisDragY: Integer;
    FAxisDragMin: Double;
    FLoading: Boolean;
    FSelecting: Boolean;          // right-drag zoom box
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

    // files / loading
    function DefaultDailyDir: string;
    procedure ScanFolder;
    function DayIndex(ADay: Integer): Integer;
    function ReadDayFile(const AFileName: string; FromPos: Int64; out T: TTimeArray;
      out V: TValueArrays; out N: Integer): Int64;
    function TailUnchanged(const AFileName: string): Boolean;
    procedure SetupSeriesFromHeader(const Line: string);
    procedure ClearData;
    procedure AppendData(const T: TTimeArray; const V: TValueArrays; AFrom, N: Integer);
    procedure PrependData(const T: TTimeArray; const V: TValueArrays; N: Integer);
    procedure LoadInitial;
    function LoadOlderDay: Boolean;
    procedure EnsureLoaded(AFrom: TDateTime);
    procedure ReadTail;
    procedure OpenFolder(const ADir: string);
    procedure ShowLoading(const AText: string);

    // view
    function TotalStart: TDateTime;
    function TotalEnd: TDateTime;
    function ViewStart: TDateTime;
    function LowerBound(T: TDateTime): Integer;
    function NearestIndex(T: TDateTime): Integer;
    procedure AutoAxes;
    procedure SetView(AEnd: TDateTime; KeepFollow: Boolean = False);
    procedure SetSpan(ASpan: TDateTime; AnchorX: Integer = -1);
    procedure UpdateScrollBar;
    procedure UpdateStatus;
    procedure SyncWindowCombo;
    function VisibleAxisCount: Integer;
    function AxisLeft(S: Integer): Integer;
    function AxisAt(X, Y: Integer): Integer;
    function PlotRect: TRect;
    procedure DrawChart(P: TChartPainter; W, H: Integer);
    function DisplayValue(S: Integer; V: Double): string;

    // events
    procedure PaintBoxPaint(Sender: TObject);
    procedure PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PaintBoxMouseLeave(Sender: TObject);
    procedure PaintBoxDblClick(Sender: TObject);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure ScrollBarChange(Sender: TObject);
    procedure CmbWindowChange(Sender: TObject);
    procedure ChkFollowChange(Sender: TObject);
    procedure BtnOlderClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure MnuOpenFolderClick(Sender: TObject);
    procedure MnuReloadClick(Sender: TObject);
    procedure MnuExitClick(Sender: TObject);
    procedure MnuFollowClick(Sender: TObject);
    procedure MnuAutoAxesClick(Sender: TObject);
    procedure MnuSeriesClick(Sender: TObject);
    procedure MnuUndoZoomClick(Sender: TObject);
    procedure MnuResetZoomClick(Sender: TObject);
    procedure PaintBoxContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure PushZoom;
    procedure UndoZoom;
    procedure ZoomToRect(const Sel: TRect);
  end;

var
  frmViewer: TfrmViewer;

implementation

{$R *.lfm}

function QueryPerformanceCounter(out Count: Int64): LongBool; stdcall; external 'kernel32.dll';
function QueryPerformanceFrequency(out Freq: Int64): LongBool; stdcall; external 'kernel32.dll';

const
  WindowSeconds: array[0..7] of Integer = (900, 3600, 10800, 21600, 43200, 86400,
    259200, 604800);
  WindowNames: array[0..7] of string = ('15 min', '1 hour', '3 hours', '6 hours',
    '12 hours', '1 day', '3 days', '7 days');
  DefaultWindowIndex = 2;
  TimeSteps: array[0..16] of Integer = (1, 5, 10, 15, 30, 60, 120, 300, 600, 900,
    1800, 3600, 7200, 10800, 21600, 43200, 86400);
  KindNames: array[TDataKind] of string = ('Boolean', 'Byte', 'Integer', 'Double');
  BackColor: TBGRAPixel = (blue: 32; green: 26; red: 24; alpha: 255);

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

{ "yyyy-mm-dd hh:nn:ss.zzz" (fast, fixed positions) or a TDateTime double }
function ParseTimeStr(const S: string; out T: TDateTime): Boolean;
var
  Y, Mo, D, H, Mi, Se, MS: Integer;
  Dbl: Double;
begin
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
    Result := TryStrToFloat(Trim(S), Dbl, FS);
    T := Dbl;
  end;
end;

function FileSizeOf(const AFileName: string): Int64;
var
  SR: TSearchRec;
begin
  Result := -1;
  if FindFirst(AFileName, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

function ParseValueStr(const S: string): Double;
begin
  if SameText(S, 'TRUE') then Result := 1
  else if SameText(S, 'FALSE') then Result := 0
  else if not TryStrToFloat(Trim(S), Result, FS) then Result := NaN;
end;

{ "Name [Type]" -> name, type (Double when missing) }
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

{ TfrmViewer }

procedure TfrmViewer.FormCreate(Sender: TObject);
var
  i: Integer;
  Dir: string;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
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
  FFirstLoadedDay := -1;
  FLastLoadedDay := -1;
  FViewSpan := DefaultSpanHours * OneHour;
  BuildUI;
  // HistoryViewer.exe [/bench] [folder]
  Dir := DefaultDailyDir;
  for i := 1 to ParamCount do
    if DirectoryExists(ParamStr(i)) then Dir := ParamStr(i);
  OpenFolder(Dir);
  if FindCmdLineSwitch('bench', ['/', '-'], True) then
  begin
    // all days of the folder, then timings
    FTimer.Enabled := False;
    while LoadOlderDay do ;
    Application.QueueAsyncCall(@RunBench, 0);
    Exit;
  end;
  FTimer.Enabled := True;
end;

destructor TfrmViewer.Destroy;
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

procedure TfrmViewer.BuildUI;
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

  // menu
  FMainMenu := TMainMenu.Create(Self);
  Menu := FMainMenu;
  MFile := TMenuItem.Create(FMainMenu);
  MFile.Caption := '&File';
  FMainMenu.Items.Add(MFile);
  AddItem(MFile, '&Open daily folder...', @MnuOpenFolderClick, ShortCut(Ord('O'), [ssCtrl]));
  AddItem(MFile, '&Reload', @MnuReloadClick, ShortCut(VK_F5, []));
  AddItem(MFile, '-', nil);
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
  FMnuFollow := AddItem(MView, '&Follow live', @MnuFollowClick, ShortCut(Ord('L'), [ssCtrl]));
  FMnuFollow.Checked := True;
  AddItem(MView, '&Undo zoom', @MnuUndoZoomClick, ShortCut(Ord('Z'), [ssCtrl]));
  AddItem(MView, 'Reset &zoom', @MnuResetZoomClick, ShortCut(Ord('0'), [ssCtrl]));
  AddItem(MView, '&Auto Y axes', @MnuAutoAxesClick, ShortCut(Ord('R'), [ssCtrl]));
  AddItem(MView, '-', nil);
  FMnuSeries := AddItem(MView, '&Data sets', nil);

  FDirDialog := TSelectDirectoryDialog.Create(Self);
  FDirDialog.Title := 'Folder with the daily CSV files';

  // toolbar
  FTopPanel := TPanel.Create(Self);
  FTopPanel.Parent := Self;
  FTopPanel.Align := alTop;
  FTopPanel.Height := 58;
  FTopPanel.BevelOuter := bvNone;

  with TLabel.Create(Self) do
  begin
    Parent := FTopPanel;
    SetBounds(10, 10, 50, 20);
    Caption := 'Window:';
  end;

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
  FChkFollow.SetBounds(168, 9, 90, 20);
  FChkFollow.Caption := 'Follow live';
  FChkFollow.Checked := True;
  FChkFollow.OnChange := @ChkFollowChange;

  FBtnOlder := TButton.Create(Self);
  FBtnOlder.Parent := FTopPanel;
  FBtnOlder.SetBounds(266, 5, 120, 26);
  FBtnOlder.Caption := 'Load older day';
  FBtnOlder.Hint := 'Read the previous day file now' + LineEnding +
    '(happens automatically when you scroll back)';
  FBtnOlder.ShowHint := True;
  FBtnOlder.OnClick := @BtnOlderClick;

  FLblStatus := TLabel.Create(Self);
  FLblStatus.Parent := FTopPanel;
  FLblStatus.SetBounds(400, 10, 900, 20);

  FLblFolder := TLabel.Create(Self);
  FLblFolder.Parent := FTopPanel;
  FLblFolder.SetBounds(10, 36, 1200, 18);
  FLblFolder.Font.Color := clGrayText;

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

  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 1000;
  FTimer.OnTimer := @TimerTick;
end;

procedure TfrmViewer.BuildSeriesMenu;
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

{ ---------- files ---------- }

{ daily folder next to the viewer, or the generator's one (..\daily) }
function TfrmViewer.DefaultDailyDir: string;
var
  ExeDir: string;
begin
  ExeDir := ExtractFilePath(Application.ExeName);
  Result := ExeDir + 'daily';
  if not DirectoryExists(Result) then
    Result := ExpandFileName(ExeDir + '..' + PathDelim + 'daily');
end;

{ Lists <prefix>_yyyy-mm-dd.csv. With several prefixes the one of the
  newest file is used. }
procedure TfrmViewer.ScanFolder;
var
  SR: TSearchRec;
  Base, DateStr, Pre, BestPre: string;
  D: TDateTime;
  BestDay, n, i, j: Integer;
  Tmp: TDayFile;
  All: array of record Pre: string; Day: Integer; FileName: string; end;
begin
  SetLength(FDays, 0);
  SetLength(All, 0);
  if FindFirst(IncludeTrailingPathDelimiter(FDir) + '*_????-??-??.csv', faAnyFile, SR) = 0 then
  try
    repeat
      Base := ChangeFileExt(SR.Name, '');
      DateStr := RightStr(Base, 10);
      Pre := Copy(Base, 1, Length(Base) - 11);
      if TryEncodeDate(StrToIntDef(Copy(DateStr, 1, 4), 0), StrToIntDef(Copy(DateStr, 6, 2), 0),
        StrToIntDef(Copy(DateStr, 9, 2), 0), D) then
      begin
        n := Length(All);
        SetLength(All, n + 1);
        All[n].Pre := Pre;
        All[n].Day := Trunc(D);
        All[n].FileName := IncludeTrailingPathDelimiter(FDir) + SR.Name;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;

  // which prefix
  if (FPrefix <> '') then
  begin
    BestPre := '';
    for i := 0 to High(All) do
      if All[i].Pre = FPrefix then BestPre := FPrefix;
  end
  else
    BestPre := '';
  if BestPre = '' then
  begin
    BestDay := -1;
    for i := 0 to High(All) do
      if All[i].Day > BestDay then
      begin
        BestDay := All[i].Day;
        BestPre := All[i].Pre;
      end;
  end;
  FPrefix := BestPre;

  for i := 0 to High(All) do
    if All[i].Pre = FPrefix then
    begin
      n := Length(FDays);
      SetLength(FDays, n + 1);
      FDays[n].Day := All[i].Day;
      FDays[n].FileName := All[i].FileName;
    end;
  // sort by day
  for i := 1 to High(FDays) do
  begin
    Tmp := FDays[i];
    j := i - 1;
    while (j >= 0) and (FDays[j].Day > Tmp.Day) do
    begin
      FDays[j + 1] := FDays[j];
      Dec(j);
    end;
    FDays[j + 1] := Tmp;
  end;
end;

function TfrmViewer.DayIndex(ADay: Integer): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(FDays) do
    if FDays[i].Day = ADay then Exit(i);
end;

procedure TfrmViewer.SetupSeriesFromHeader(const Line: string);
var
  Parts: TStringList;
  s: Integer;
begin
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Line;
    FSeriesCount := Min(MaxSeries, Parts.Count - 1);
    for s := 0 to FSeriesCount - 1 do
    begin
      SplitHeaderName(Parts[s + 1], FSeries[s].Name, FSeries[s].Kind);
      if FSeries[s].Name = '' then FSeries[s].Name := 'Set ' + IntToStr(s + 1);
      FSeries[s].Color := Palette[s];
      FSeries[s].Visible := True;
      FSeries[s].AxisUser := False;
    end;
  finally
    Parts.Free;
  end;
  BuildSeriesMenu;
end;

{ Reads complete lines of AFileName from byte FromPos on. Returns the new
  position (after the last complete line); an unfinished last line is
  left for the next call. The first header seen defines the data sets. }
function TfrmViewer.ReadDayFile(const AFileName: string; FromPos: Int64;
  out T: TTimeArray; out V: TValueArrays; out N: Integer): Int64;
var
  F: TFileStream;
  Buf, Line: string;
  Size: Int64;
  P, Q, LastLF, s, Cap, FieldStart, FieldEnd: Integer;
  TT: TDateTime;
begin
  Result := FromPos;
  N := 0;
  SetLength(T, 0);
  for s := 0 to MaxSeries - 1 do
    SetLength(V[s], 0);

  F := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    Size := F.Size;
    if Size <= FromPos then Exit;
    F.Position := FromPos;
    SetLength(Buf, Size - FromPos);
    F.ReadBuffer(Buf[1], Length(Buf));
  finally
    F.Free;
  end;

  LastLF := RPos(#10, Buf);
  if LastLF = 0 then Exit;     // no complete line yet
  Result := FromPos + LastLF;
  P := RPosEx(#10, Buf, LastLF - 1);
  FTailCheck := Copy(Buf, P + 1, LastLF - P);

  Cap := LastLF div 30 + 16;   // rough line count
  SetLength(T, Cap);
  for s := 0 to MaxSeries - 1 do
    SetLength(V[s], Cap);

  P := 1;
  while P <= LastLF do
  begin
    Q := PosEx(#10, Buf, P);
    if Q = 0 then Q := LastLF + 1;
    Line := Copy(Buf, P, Q - P);
    P := Q + 1;
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    if Line = '' then Continue;

    if StartsText('Time', Line) then
    begin
      if FSeriesCount = 0 then SetupSeriesFromHeader(Line);
      Continue;
    end;
    if FSeriesCount = 0 then Continue;

    FieldEnd := Pos(';', Line);
    if FieldEnd = 0 then Continue;
    if not ParseTimeStr(Copy(Line, 1, FieldEnd - 1), TT) then Continue;

    if N >= Cap then
    begin
      Cap := Cap * 2;
      SetLength(T, Cap);
      for s := 0 to MaxSeries - 1 do
        SetLength(V[s], Cap);
    end;
    T[N] := TT;
    for s := 0 to FSeriesCount - 1 do
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
end;

{ True when the last line we read is still at the same place, i.e. the
  file was only appended to (not rewritten by the generator) }
function TfrmViewer.TailUnchanged(const AFileName: string): Boolean;
var
  F: TFileStream;
  Buf: string;
begin
  Result := True;
  if (FTailCheck = '') or (FTailPos < Length(FTailCheck)) then Exit;
  try
    F := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      if F.Size < FTailPos then Exit(False);
      F.Position := FTailPos - Length(FTailCheck);
      SetLength(Buf, Length(FTailCheck));
      F.ReadBuffer(Buf[1], Length(Buf));
      Result := Buf = FTailCheck;
    finally
      F.Free;
    end;
  except
    Result := True;           // locked for a moment - try again next time
  end;
end;

procedure TfrmViewer.ClearData;
var
  s: Integer;
begin
  Inc(FDataVersion);           // index is rebuilt
  FCount := 0;
  SetLength(FTimes, 0);
  for s := 0 to MaxSeries - 1 do
    SetLength(FData[s], 0);
  FFirstLoadedDay := -1;
  FLastLoadedDay := -1;
  FTailPos := 0;
  FTailCheck := '';
end;

{ Appends samples AFrom..N-1 of T / V }
procedure TfrmViewer.AppendData(const T: TTimeArray; const V: TValueArrays; AFrom, N: Integer);
var
  s, NewCap: Integer;
begin
  N := N - AFrom;
  if N <= 0 then Exit;
  if FCount + N > Length(FTimes) then
  begin
    NewCap := Max(FCount + N + 4096, Length(FTimes) * 3 div 2);
    SetLength(FTimes, NewCap);
    for s := 0 to MaxSeries - 1 do
      SetLength(FData[s], NewCap);
  end;
  Move(T[AFrom], FTimes[FCount], N * SizeOf(TDateTime));
  for s := 0 to FSeriesCount - 1 do
    Move(V[s][AFrom], FData[s][FCount], N * SizeOf(Double));
  Inc(FCount, N);
end;

procedure TfrmViewer.PrependData(const T: TTimeArray; const V: TValueArrays; N: Integer);
var
  NT: TTimeArray;
  ND: TDoubleArray;
  s, NewCap: Integer;
begin
  if N <= 0 then Exit;
  Inc(FDataVersion);           // samples in front: index is rebuilt
  NewCap := N + FCount + 4096;
  SetLength(NT, NewCap);
  Move(T[0], NT[0], N * SizeOf(TDateTime));
  if FCount > 0 then
    Move(FTimes[0], NT[N], FCount * SizeOf(TDateTime));
  FTimes := NT;
  for s := 0 to FSeriesCount - 1 do
  begin
    ND := nil;
    SetLength(ND, NewCap);
    Move(V[s][0], ND[0], N * SizeOf(Double));
    if FCount > 0 then
      Move(FData[s][0], ND[N], FCount * SizeOf(Double));
    FData[s] := ND;
  end;
  Inc(FCount, N);
end;

procedure TfrmViewer.ShowLoading(const AText: string);
begin
  FLblStatus.Caption := AText;
  FLblStatus.Repaint;
  Screen.Cursor := crHourGlass;
end;

{ Newest day only (the view then asks for older days if it needs them) }
procedure TfrmViewer.LoadInitial;
var
  T: TTimeArray;
  V: TValueArrays;
  N, k: Integer;
begin
  ClearData;
  FSeriesCount := 0;
  BuildSeriesMenu;
  if Length(FDays) = 0 then Exit;
  k := High(FDays);
  ShowLoading('Loading ' + ExtractFileName(FDays[k].FileName) + ' ...');
  try
    FTailPos := ReadDayFile(FDays[k].FileName, 0, T, V, N);
    AppendData(T, V, 0, N);
    FFirstLoadedDay := FDays[k].Day;
    FLastLoadedDay := FDays[k].Day;
  finally
    Screen.Cursor := crDefault;
  end;
end;

{ Reads the day before the oldest loaded one and puts it in front }
function TfrmViewer.LoadOlderDay: Boolean;
var
  T: TTimeArray;
  V: TValueArrays;
  N, k: Integer;
  Check: string;
begin
  Result := False;
  if FLoading or (FFirstLoadedDay < 0) then Exit;
  k := DayIndex(FFirstLoadedDay);
  if k <= 0 then Exit;        // nothing older
  Dec(k);
  FLoading := True;
  ShowLoading('Loading older data: ' + ExtractFileName(FDays[k].FileName) + ' ...');
  Check := FTailCheck;
  try
    ReadDayFile(FDays[k].FileName, 0, T, V, N);
    FTailCheck := Check;
    // keep strict time order: only samples before the current first one
    while (N > 0) and (FCount > 0) and (T[N - 1] >= FTimes[0]) do Dec(N);
    PrependData(T, V, N);
    FFirstLoadedDay := FDays[k].Day;
    Result := True;
  finally
    FLoading := False;
    Screen.Cursor := crDefault;
  end;
  AutoAxes;
end;

{ Loads older days until AFrom is covered (or no older file exists) }
procedure TfrmViewer.EnsureLoaded(AFrom: TDateTime);
begin
  while (FFirstLoadedDay >= 0) and (DayIndex(FFirstLoadedDay) > 0) and
        (AFrom < FFirstLoadedDay) do
    if not LoadOlderDay then Break;
end;

{ New lines of the newest day file, and a new day file after midnight }
procedure TfrmViewer.ReadTail;
var
  T: TTimeArray;
  V: TValueArrays;
  N, k, OldCount, First: Integer;
  Size: Int64;
begin
  if (FLastLoadedDay < 0) or FLoading then Exit;
  OldCount := FCount;
  k := DayIndex(FLastLoadedDay);
  if k < 0 then Exit;
  if not FileExists(FDays[k].FileName) then Exit;
  Size := FileSizeOf(FDays[k].FileName);
  if (Size < FTailPos) or not TailUnchanged(FDays[k].FileName) then
  begin
    // file was rewritten (e.g. new data generated) -> read everything again
    MnuReloadClick(nil);
    Exit;
  end;
  if Size > FTailPos then
  begin
    FTailPos := ReadDayFile(FDays[k].FileName, FTailPos, T, V, N);
    // skip samples we already have (keeps the times ascending)
    First := 0;
    while (First < N) and (FCount > 0) and (T[First] <= FTimes[FCount - 1]) do
      Inc(First);
    AppendData(T, V, First, N);
  end;

  // a newer day file?  (checked every 5 s)
  Inc(FTick);
  if FTick mod 5 = 0 then
  begin
    ScanFolder;
    k := DayIndex(FLastLoadedDay);
    if (k >= 0) and (k < High(FDays)) then
    begin
      Inc(k);
      FTailPos := ReadDayFile(FDays[k].FileName, 0, T, V, N);
      First := 0;
      while (First < N) and (FCount > 0) and (T[First] <= FTimes[FCount - 1]) do
        Inc(First);
      AppendData(T, V, First, N);
      FLastLoadedDay := FDays[k].Day;
    end;
  end;

  if FCount <> OldCount then
  begin
    if FChkFollow.Checked then
      SetView(TotalEnd, True)
    else
    begin
      UpdateScrollBar;
      UpdateStatus;
      FPaintBox.Invalidate;
    end;
  end;
end;

procedure TfrmViewer.OpenFolder(const ADir: string);
begin
  FDir := ExcludeTrailingPathDelimiter(ADir);
  FPrefix := '';
  FLblFolder.Caption := 'Folder: ' + FDir;
  ScanFolder;
  LoadInitial;
  AutoAxes;
  FChkFollow.Checked := True;
  SetView(TotalEnd, True);
end;

{ ---------- view ---------- }

function TfrmViewer.TotalStart: TDateTime;
begin
  if Length(FDays) > 0 then Result := FDays[0].Day
  else if FCount > 0 then Result := FTimes[0]
  else Result := Now - FViewSpan;
  if (FCount > 0) and (Length(FDays) > 0) and (FFirstLoadedDay = FDays[0].Day) then
    Result := FTimes[0];     // oldest file loaded -> start at its first sample
end;

function TfrmViewer.TotalEnd: TDateTime;
begin
  if FCount > 0 then Result := FTimes[FCount - 1]
  else Result := Now;
end;

function TfrmViewer.ViewStart: TDateTime;
begin
  Result := FViewEnd - FViewSpan;
end;

{ first index with time >= T }
function TfrmViewer.LowerBound(T: TDateTime): Integer;
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

function TfrmViewer.NearestIndex(T: TDateTime): Integer;
begin
  Result := -1;
  if FCount = 0 then Exit;
  Result := Min(LowerBound(T), FCount - 1);
  if (Result > 0) and (Abs(FTimes[Result - 1] - T) < Abs(FTimes[Result] - T)) then
    Dec(Result);
end;

{ Y ranges that are not set by the user: one common range for the
  numeric sets (so their heights compare), FALSE/TRUE for Boolean }
procedure TfrmViewer.AutoAxes;
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

{ Moves the view so it ends at AEnd; loads older days when needed }
procedure TfrmViewer.SetView(AEnd: TDateTime; KeepFollow: Boolean);
var
  TS, TE: TDateTime;
begin
  // older data needed (plus half a window in advance)?
  EnsureLoaded(AEnd - FViewSpan * 1.5);
  TS := TotalStart;
  TE := TotalEnd;
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

procedure TfrmViewer.SetSpan(ASpan: TDateTime; AnchorX: Integer);
var
  R: TRect;
  Frac, Anchor: Double;
begin
  ASpan := EnsureRange(ASpan, MinSpanSeconds * OneSecond, 31.0);
  R := PlotRect;
  if (AnchorX < 0) or (R.Width <= 0) or FChkFollow.Checked then
  begin
    // keep the right edge (follow live) or the middle
    if FChkFollow.Checked then
    begin
      FViewSpan := ASpan;
      SetView(TotalEnd, True);
    end
    else
    begin
      Anchor := FViewEnd - FViewSpan / 2;
      FViewSpan := ASpan;
      SetView(Anchor + ASpan / 2);
    end;
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

procedure TfrmViewer.SyncWindowCombo;
var
  i, Idx: Integer;
begin
  Idx := -1;
  for i := Low(WindowSeconds) to High(WindowSeconds) do
    if Abs(FViewSpan * SecsPerDay - WindowSeconds[i]) < 0.5 then Idx := i;
  if FCmbWindow.ItemIndex <> Idx then FCmbWindow.ItemIndex := Idx;
end;

{ Scrollbar in seconds over all available days (loaded or not) }
procedure TfrmViewer.UpdateScrollBar;
var
  TotalSec, PageSec, PosSec: Integer;
begin
  FUpdatingScroll := True;
  try
    TotalSec := Max(1, Round((TotalEnd - TotalStart) * SecsPerDay));
    PageSec := EnsureRange(Round(FViewSpan * SecsPerDay), 1, TotalSec);
    PosSec := EnsureRange(Round((ViewStart - TotalStart) * SecsPerDay), 0, TotalSec);
    FScrollBar.SetParams(PosSec, 0, TotalSec, PageSec);
    FScrollBar.LargeChange := EnsureRange(PageSec div 2, 1, 32767);   // TScrollBarInc = 1..32767
    FScrollBar.SmallChange := EnsureRange(PageSec div 20, 1, 32767);
  finally
    FUpdatingScroll := False;
  end;
end;

procedure TfrmViewer.UpdateStatus;
const
  F = 'dd/mm/yyyy';
var
  Avail, LoadedTxt: string;
begin
  if Length(FDays) = 0 then
  begin
    FLblStatus.Caption := 'No daily files (<name>_yyyy-mm-dd.csv) in this folder';
    Exit;
  end;
  Avail := Format('%d day(s) %s - %s', [Length(FDays),
    FormatDateTime(F, FDays[0].Day), FormatDateTime(F, FDays[High(FDays)].Day)]);
  if FFirstLoadedDay >= 0 then
    LoadedTxt := Format('loaded %s - %s', [FormatDateTime(F, FFirstLoadedDay),
      FormatDateTime(F, FLastLoadedDay)])
  else
    LoadedTxt := 'nothing loaded';
  FLblStatus.Caption := Format('%s  |  %s  |  %d samples  |  view %s - %s', [Avail, LoadedTxt,
    FCount, FormatDateTime('dd/mm hh:nn:ss', ViewStart), FormatDateTime('dd/mm hh:nn:ss', FViewEnd)]);
  FBtnOlder.Enabled := (FFirstLoadedDay >= 0) and (DayIndex(FFirstLoadedDay) > 0);
  UpdateDataGrid;
end;

function TfrmViewer.VisibleAxisCount: Integer;
var
  s: Integer;
begin
  Result := 0;
  for s := 0 to FSeriesCount - 1 do
    if FSeries[s].Visible then Inc(Result);
end;

function TfrmViewer.AxisLeft(S: Integer): Integer;
var
  i, n: Integer;
begin
  if not FSeries[S].Visible then Exit(-1);
  n := 0;
  for i := 0 to S - 1 do
    if FSeries[i].Visible then Inc(n);
  Result := 4 + n * AxisWidth;
end;

function TfrmViewer.AxisAt(X, Y: Integer): Integer;
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

function TfrmViewer.PlotRect: TRect;
begin
  Result := Rect(8 + Max(1, VisibleAxisCount) * AxisWidth, 52,
    FPaintBox.Width - 16, FPaintBox.Height - XAxisHeight - 4);
end;

function TfrmViewer.DisplayValue(S: Integer; V: Double): string;
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
procedure TfrmViewer.UpdateDataGrid(Columns: Boolean);
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

function TfrmViewer.DataGridCell(Row, Col: Integer): string;
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
procedure TfrmViewer.DataGridRowDblClick(Sender: TObject; Row: Integer);
var
  i: Integer;
begin
  i := FGridFirst + Row;
  if (i < 0) or (i >= FCount) then Exit;
  FChkFollow.Checked := False;
  SetView(FTimes[i] + FViewSpan / 2);
end;

procedure TfrmViewer.MnuDataGridClick(Sender: TObject);
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

procedure TfrmViewer.MnuGridLinesClick(Sender: TObject);
begin
  FShowGrid := not FShowGrid;
  FMnuGridLines.Checked := FShowGrid;
  FPaintBox.Invalidate;
end;

{ ---------- drawing ---------- }

procedure TfrmViewer.DrawChart(P: TChartPainter; W, H: Integer);
var
  R: TRect;
  M: TXMap;
  PW, PH, s, i, i0, i1, Step, AxL, AxX, NTicks, Idx, px, CurPx, BCount: Integer;
  TStart, Span, SpanSec, T0Sec, TSec, YStep, V, BMin, BMax, BFirst, BLast, LastY: Double;
  X, Yf, LegendX, BX: Single;
  Pts: array of TPointF;
  NPts: Integer;
  Fmt, Txt: string;
  C, Dim: TBGRAPixel;
  Day: Integer;

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
  var
    Seg: array of TPointF;
  begin
    if NPts >= 2 then
    begin
      Seg := Copy(Pts, 0, NPts);
      P.Polyline(Seg, FSeries[S].Color, 1.5);
    end
    else if NPts = 1 then
      P.Circle(Pts[0].X, Pts[0].Y, 1.5, FSeries[S].Color, BGRAPixelTransparent, 0);
    NPts := 0;
  end;

  // one pixel column: a single sample, or its first/min/max/last values
  procedure EmitBucket(S: Integer);
  var
    PX0: Single;
  begin
    if BCount = 0 then Exit;
    if BCount = 1 then
    begin
      Yf := YOf(S, BFirst);
      if (FSeries[S].Kind = dkBoolean) and (NPts > 0) and (Pts[NPts - 1].Y <> Yf) then
        AddPt(BX, Pts[NPts - 1].Y);       // square step
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

  if FSeriesCount = 0 then
  begin
    P.Text((R.Left + R.Right) / 2, (R.Top + R.Bottom) / 2 - 8,
      'No data - File > Open daily folder...', BGRA(170, 170, 180), taCenter);
    Exit;
  end;

  // area without any file (before the oldest day) or not loaded yet
  if (FCount > 0) and (FTimes[0] > TStart) then
  begin
    X := Min(XOf(FTimes[0]), R.Right);
    P.FillRect(R.Left, R.Top, X, R.Bottom, BGRA(255, 255, 255, 10));
    if (FFirstLoadedDay >= 0) and (DayIndex(FFirstLoadedDay) > 0) then
      Txt := 'older data not loaded yet'
    else
      Txt := 'no data';
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

  // day boundaries = file boundaries
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
        // gap in time -> do not join
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

procedure TfrmViewer.PaintBoxPaint(Sender: TObject);
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
procedure TfrmViewer.EnsureIndex;
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
function TfrmViewer.ChartSignature(W, H: Integer): string;
var
  i: Integer;
  LastT: Double;
begin
  if FCount > 0 then LastT := FTimes[FCount - 1] else LastT := 0;
  Result := Format('%d|%d|%d|%d|%.12g|%.12g|%.12g|%d|%d|%d|%s',
    [W, H, FCount, FDataVersion, LastT, FViewEnd, FViewSpan, Ord(FShowGrid), FAxisDrag,
     FSeriesCount, IntToStr(FFirstLoadedDay) + '/' + IntToStr(FLastLoadedDay)]);
  for i := 0 to FSeriesCount - 1 do
    with FSeries[i] do
      Result := Result + Format('|%.9g|%.9g|%d|%d|%d',
        [AxisMin, AxisMax, Ord(Visible), LongInt(Color), Ord(Kind)]);
end;

{ cached chart (rendered again only when the signature changes) + overlay }
procedure TfrmViewer.RenderFrame(Dest: TBGRABitmap);
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
procedure TfrmViewer.DrawOverlay(P: TChartPainter);
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
        'right-drag / drag X axis = scroll (older days load automatically), drag Y axis = move',
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
procedure TfrmViewer.RunBench(Data: PtrInt);
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
    SL.Add(Format('TfrmViewer bench  %s  samples %d  chart 1200 x 600',
      [{$ifopt R+}'DEBUG (range checks)'{$else}'RELEASE'{$endif}, FCount]));
    FViewSpan := Max(TotalEnd - TotalStart, 60 * OneSecond);
    SetView(TotalEnd, True);
    Measure('all data');
    FViewSpan := 600 * OneSecond;
    SetView(TotalEnd, True);
    Measure('10 min window');
    SL.SaveToFile(ExtractFilePath(ParamStr(0)) + 'bench.txt');
  finally
    Bmp.Free;
    SL.Free;
  end;
  Application.Terminate;
end;

{ ---------- mouse ---------- }

procedure TfrmViewer.PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
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

procedure TfrmViewer.PaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
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

procedure TfrmViewer.PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
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
  end;
  FDragging := False;
  FAxisDrag := -1;
  FPaintBox.Cursor := crDefault;
  FPaintBox.Invalidate;
end;

procedure TfrmViewer.PaintBoxMouseLeave(Sender: TObject);
begin
  FHoverX := -1;
  FPaintBox.Invalidate;
end;

procedure TfrmViewer.PaintBoxDblClick(Sender: TObject);
var
  A: Integer;
begin
  A := AxisAt(FHoverX, FHoverY);
  if A < 0 then Exit;
  FSeries[A].AxisUser := False;
  AutoAxes;
  FPaintBox.Invalidate;
end;

procedure TfrmViewer.FormMouseWheel(Sender: TObject; Shift: TShiftState;
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

procedure TfrmViewer.ScrollBarChange(Sender: TObject);
begin
  if FUpdatingScroll then Exit;
  SetView(TotalStart + (FScrollBar.Position * OneSecond) + FViewSpan);
end;

procedure TfrmViewer.CmbWindowChange(Sender: TObject);
begin
  if FCmbWindow.ItemIndex >= 0 then
    SetSpan(WindowSeconds[FCmbWindow.ItemIndex] * OneSecond);
end;

procedure TfrmViewer.ChkFollowChange(Sender: TObject);
begin
  FMnuFollow.Checked := FChkFollow.Checked;
  if FChkFollow.Checked then
    SetView(TotalEnd, True);
end;

procedure TfrmViewer.BtnOlderClick(Sender: TObject);
begin
  if LoadOlderDay then
  begin
    UpdateScrollBar;
    UpdateStatus;
    FPaintBox.Invalidate;
  end;
end;

procedure TfrmViewer.TimerTick(Sender: TObject);
begin
  ReadTail;
end;

procedure TfrmViewer.MnuOpenFolderClick(Sender: TObject);
begin
  FDirDialog.InitialDir := FDir;
  if FDirDialog.Execute then
    OpenFolder(FDirDialog.FileName);
end;

{ Reads the files again, keeping the time window and the position }
procedure TfrmViewer.MnuReloadClick(Sender: TObject);
var
  KeepEnd: TDateTime;
  Follow: Boolean;
  s: Integer;
  User: array[0..MaxSeries - 1] of TSeriesInfo;
begin
  KeepEnd := FViewEnd;
  Follow := FChkFollow.Checked;
  for s := 0 to MaxSeries - 1 do
    User[s] := FSeries[s];
  ScanFolder;
  LoadInitial;
  for s := 0 to FSeriesCount - 1 do
    if User[s].AxisUser then
    begin
      FSeries[s].AxisMin := User[s].AxisMin;
      FSeries[s].AxisMax := User[s].AxisMax;
      FSeries[s].AxisUser := True;
    end;
  AutoAxes;
  if Follow then SetView(TotalEnd, True) else SetView(KeepEnd);
end;

procedure TfrmViewer.MnuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmViewer.MnuFollowClick(Sender: TObject);
begin
  FChkFollow.Checked := not FChkFollow.Checked;
end;

procedure TfrmViewer.MnuAutoAxesClick(Sender: TObject);
var
  s: Integer;
begin
  for s := 0 to FSeriesCount - 1 do
    FSeries[s].AxisUser := False;
  AutoAxes;
  FPaintBox.Invalidate;
end;

{ ---------- zoom box ---------- }

{ the right button scrolls the chart - no popup menu }
procedure TfrmViewer.PaintBoxContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
begin
  Handled := True;
end;

procedure TfrmViewer.PushZoom;
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

procedure TfrmViewer.UndoZoom;
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
    SetView(TotalEnd, True);
  end
  else
    SetView(Z.ViewEnd);
  SyncWindowCombo;
end;

{ the selected time range and value range fill the plot }
procedure TfrmViewer.ZoomToRect(const Sel: TRect);
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

procedure TfrmViewer.MnuUndoZoomClick(Sender: TObject);
begin
  UndoZoom;
end;

{ back to the default view: auto Y axes, 3 hours, follow live }
procedure TfrmViewer.MnuResetZoomClick(Sender: TObject);
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
  SetView(TotalEnd, True);
end;

procedure TfrmViewer.MnuSeriesClick(Sender: TObject);
var
  s: Integer;
begin
  s := TMenuItem(Sender).Tag;
  FSeries[s].Visible := not FSeries[s].Visible;
  TMenuItem(Sender).Checked := FSeries[s].Visible;
  FPaintBox.Invalidate;
end;

end.
