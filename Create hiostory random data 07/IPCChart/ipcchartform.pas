unit IPCChartForm;

{
  IPC chart client
  ----------------
  Connects to the IPC server of HistoryRandomData (TCP, see IPCData.pas),
  asks for the recent history (default 3 hours), subscribes to the live
  samples and charts them.

  * Scrolling back past the oldest received sample asks the server for
    more history ("HISTORY <seconds>") - loaded on demand.
  * RESET from the server (data regenerated) -> history is requested again.
  * Lost connection -> automatic reconnect (every 3 s).
  * Chart: one Y axis per data set (drag = move, wheel = zoom, double-click =
    auto range), wheel = zoom time, drag = scroll, hover = values.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DateUtils, StrUtils, Forms, Controls, Graphics,
  ExtCtrls, StdCtrls, Spin, Menus, LCLType, BGRABitmap, BGRABitmapTypes,
  ChartPainter, IPCData;

const
  MaxSeries = 8;
  GapSeconds = 3.0;
  AxisWidth = 58;
  XAxisHeight = 26;
  MinSpanSeconds = 10;
  ReconnectSeconds = 3;
  PingSeconds = 5;
  DeadSeconds = 15;            // nothing received this long -> reconnect

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

  { TfrmIPCChart }

  TfrmIPCChart = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    // UI
    FMainMenu: TMainMenu;
    FMnuSeries, FMnuFollow: TMenuItem;
    FTopPanel: TPanel;
    FEdtHost: TEdit;
    FSpnPort: TSpinEdit;
    FBtnConnect: TButton;
    FChkReconnect: TCheckBox;
    FCmbHistory, FCmbWindow: TComboBox;
    FChkFollow: TCheckBox;
    FBtnMore: TButton;
    FLblState, FLblStatus: TLabel;
    FShpState: TShape;
    FPaintBox: TPaintBox;
    FScrollBar: TScrollBar;
    FPoll: TTimer;

    // connection
    FClient: TIPCDataClient;
    FWantConnected: Boolean;
    FStarted: Boolean;          // HISTORY + SUBSCRIBE sent on this connection
    FServerInfo: string;
    FIntervalMs: Integer;
    FReconnectAt, FLastRx, FLastPing: TDateTime;
    FLastError: string;
    FRxLines: TStringList;

    // history requests
    FHistorySeconds: Integer;   // currently held span asked from the server (0 = all)
    FHistPending: Boolean;
    FHistForOlder: Boolean;     // request made to get older data
    FFirstBefore: TDateTime;    // oldest sample before that request
    FNoMoreHistory: Boolean;
    FInHistory: Boolean;
    FHT: TTimeArray;            // history block being received
    FHV: TValueArrays;
    FHN: Integer;

    // data
    FSeriesCount: Integer;
    FSeries: array[0..MaxSeries - 1] of TSeriesInfo;
    FTimes: TTimeArray;
    FData: TValueArrays;
    FCount: Integer;
    FLiveCount: Integer;
    FRateTime: TDateTime;
    FRate: Double;
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

    procedure BuildUI;
    procedure BuildSeriesMenu;

    // connection
    procedure Connect;
    procedure Disconnect;
    procedure SendCmd(const S: string);
    procedure RequestHistory(Seconds: Integer; ForOlder: Boolean = False);
    procedure PollTick(Sender: TObject);
    procedure HandleLine(const Line: string);
    procedure SetupSeries(const Header: string);
    function ParseSample(const S: string; out T: TDateTime;
      out Vals: array of Double): Boolean;
    procedure AddSample(T: TDateTime; const Vals: array of Double);
    procedure HistoryDone;
    procedure UpdateConnState;

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
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure ScrollBarChange(Sender: TObject);
    procedure BtnConnectClick(Sender: TObject);
    procedure BtnMoreClick(Sender: TObject);
    procedure CmbHistoryChange(Sender: TObject);
    procedure CmbWindowChange(Sender: TObject);
    procedure ChkFollowChange(Sender: TObject);
    procedure MnuExitClick(Sender: TObject);
    procedure MnuFollowClick(Sender: TObject);
    procedure MnuAutoAxesClick(Sender: TObject);
    procedure MnuSeriesClick(Sender: TObject);
  end;

var
  frmIPCChart: TfrmIPCChart;

implementation

{$R *.lfm}

const
  WindowSeconds: array[0..7] of Integer = (60, 600, 3600, 10800, 21600, 43200,
    86400, 259200);
  WindowNames: array[0..7] of string = ('1 min', '10 min', '1 hour', '3 hours',
    '6 hours', '12 hours', '1 day', '3 days');
  DefaultWindowIndex = 3;
  HistorySeconds: array[0..6] of Integer = (600, 3600, 10800, 43200, 86400, 259200, 0);
  HistoryNames: array[0..6] of string = ('10 min', '1 hour', '3 hours', '12 hours',
    '1 day', '3 days', 'All');
  DefaultHistoryIndex = 2;
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

function ParseValueStr(const S: string): Double;
begin
  if SameText(S, 'TRUE') then Result := 1
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

{ TfrmIPCChart }

procedure TfrmIPCChart.FormCreate(Sender: TObject);
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

  FRxLines := TStringList.Create;
  FHoverX := -1;
  FAxisDrag := -1;
  FIntervalMs := 500;
  FViewSpan := 3 * OneHour;
  FViewEnd := Now;
  FHistorySeconds := HistorySeconds[DefaultHistoryIndex];
  BuildUI;

  // IPCChart.exe [host [port]]
  if ParamCount >= 1 then FEdtHost.Text := ParamStr(1);
  if ParamCount >= 2 then FSpnPort.Value := StrToIntDef(ParamStr(2), IPCDefaultPort);

  FPoll.Enabled := True;
  Connect;
end;

procedure TfrmIPCChart.FormDestroy(Sender: TObject);
begin
  FPoll.Enabled := False;
  FreeAndNil(FClient);
  FRxLines.Free;
end;

procedure TfrmIPCChart.BuildUI;
var
  MFile, MView: TMenuItem;
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

  function AddLabel(X, Y: Integer; const ACaption: string): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := FTopPanel;
    Result.SetBounds(X, Y, 60, 20);
    Result.Caption := ACaption;
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
  FMnuFollow := AddItem(MView, '&Follow live', @MnuFollowClick, ShortCut(Ord('L'), [ssCtrl]));
  FMnuFollow.Checked := True;
  AddItem(MView, '&Auto Y axes', @MnuAutoAxesClick, ShortCut(Ord('R'), [ssCtrl]));
  AddItem(MView, '-', nil);
  FMnuSeries := AddItem(MView, '&Data sets', nil);

  FTopPanel := TPanel.Create(Self);
  FTopPanel.Parent := Self;
  FTopPanel.Align := alTop;
  FTopPanel.Height := 68;
  FTopPanel.BevelOuter := bvNone;

  // row 1: connection
  AddLabel(10, 10, 'Server');
  FEdtHost := TEdit.Create(Self);
  FEdtHost.Parent := FTopPanel;
  FEdtHost.SetBounds(60, 6, 120, 24);
  FEdtHost.Text := '127.0.0.1';

  AddLabel(190, 10, 'Port');
  FSpnPort := TSpinEdit.Create(Self);
  FSpnPort.Parent := FTopPanel;
  FSpnPort.SetBounds(222, 6, 76, 24);
  FSpnPort.MinValue := 1;
  FSpnPort.MaxValue := 65535;
  FSpnPort.Value := IPCDefaultPort;

  FBtnConnect := TButton.Create(Self);
  FBtnConnect.Parent := FTopPanel;
  FBtnConnect.SetBounds(306, 5, 96, 26);
  FBtnConnect.Caption := 'Disconnect';
  FBtnConnect.OnClick := @BtnConnectClick;

  FChkReconnect := TCheckBox.Create(Self);
  FChkReconnect.Parent := FTopPanel;
  FChkReconnect.SetBounds(410, 9, 120, 20);
  FChkReconnect.Caption := 'Auto reconnect';
  FChkReconnect.Checked := True;

  AddLabel(536, 10, 'History');
  FCmbHistory := TComboBox.Create(Self);
  FCmbHistory.Parent := FTopPanel;
  FCmbHistory.SetBounds(586, 6, 84, 24);
  FCmbHistory.Style := csDropDownList;
  for i := Low(HistoryNames) to High(HistoryNames) do
    FCmbHistory.Items.Add(HistoryNames[i]);
  FCmbHistory.ItemIndex := DefaultHistoryIndex;
  FCmbHistory.Hint := 'How much history to ask the server for when connecting';
  FCmbHistory.ShowHint := True;
  FCmbHistory.OnChange := @CmbHistoryChange;

  FShpState := TShape.Create(Self);
  FShpState.Parent := FTopPanel;
  FShpState.Shape := stCircle;
  FShpState.SetBounds(684, 11, 14, 14);
  FLblState := TLabel.Create(Self);
  FLblState.Parent := FTopPanel;
  FLblState.SetBounds(704, 10, 600, 20);

  // row 2: view
  AddLabel(10, 42, 'Window');
  FCmbWindow := TComboBox.Create(Self);
  FCmbWindow.Parent := FTopPanel;
  FCmbWindow.SetBounds(60, 38, 84, 24);
  FCmbWindow.Style := csDropDownList;
  for i := Low(WindowNames) to High(WindowNames) do
    FCmbWindow.Items.Add(WindowNames[i]);
  FCmbWindow.ItemIndex := DefaultWindowIndex;
  FCmbWindow.OnChange := @CmbWindowChange;

  FChkFollow := TCheckBox.Create(Self);
  FChkFollow.Parent := FTopPanel;
  FChkFollow.SetBounds(156, 41, 90, 20);
  FChkFollow.Caption := 'Follow live';
  FChkFollow.Checked := True;
  FChkFollow.OnChange := @ChkFollowChange;

  FBtnMore := TButton.Create(Self);
  FBtnMore.Parent := FTopPanel;
  FBtnMore.SetBounds(250, 37, 152, 26);
  FBtnMore.Caption := 'Request older data';
  FBtnMore.Hint := 'Ask the server for one more window of history' + LineEnding +
    '(happens automatically when you scroll back)';
  FBtnMore.ShowHint := True;
  FBtnMore.OnClick := @BtnMoreClick;

  FLblStatus := TLabel.Create(Self);
  FLblStatus.Parent := FTopPanel;
  FLblStatus.SetBounds(410, 42, 900, 20);

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

  FPoll := TTimer.Create(Self);
  FPoll.Enabled := False;
  FPoll.Interval := 100;
  FPoll.OnTimer := @PollTick;
end;

procedure TfrmIPCChart.BuildSeriesMenu;
var
  s: Integer;
  Item: TMenuItem;
begin
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

{ ---------- connection ---------- }

procedure TfrmIPCChart.Connect;
begin
  FreeAndNil(FClient);
  FWantConnected := True;
  FStarted := False;
  FHistPending := False;
  FInHistory := False;
  FLastError := '';
  FServerInfo := '';
  FClient := TIPCDataClient.Create(Trim(FEdtHost.Text), FSpnPort.Value);
  FLastRx := Now;
  FBtnConnect.Caption := 'Disconnect';
  FEdtHost.Enabled := False;
  FSpnPort.Enabled := False;
  UpdateConnState;
end;

procedure TfrmIPCChart.Disconnect;
begin
  FWantConnected := False;
  FreeAndNil(FClient);
  FBtnConnect.Caption := 'Connect';
  FEdtHost.Enabled := True;
  FSpnPort.Enabled := True;
  UpdateConnState;
end;

procedure TfrmIPCChart.SendCmd(const S: string);
begin
  if Assigned(FClient) and (FClient.State = csConnected) then
    FClient.Send(S);
end;

procedure TfrmIPCChart.RequestHistory(Seconds: Integer; ForOlder: Boolean);
begin
  if not Assigned(FClient) or (FClient.State <> csConnected) then Exit;
  FHistorySeconds := Seconds;
  FHistForOlder := ForOlder and (FCount > 0);
  FFirstBefore := FirstTime;
  if not ForOlder then
    FNoMoreHistory := False;
  FHistPending := True;
  SendCmd('HISTORY ' + IntToStr(Seconds));
  UpdateStatus;
end;

{ Received lines, connection watchdog, reconnect }
procedure TfrmIPCChart.PollTick(Sender: TObject);
var
  i: Integer;
  St: TIPCClientState;
begin
  if Assigned(FClient) then
  begin
    St := FClient.State;
    if (St = csConnected) and not FStarted then
    begin
      FStarted := True;
      FLastRx := Now;
      FLastPing := Now;
      FNoMoreHistory := False;
      if FCount > 0 then
        // reconnected: get at least what we already show
        RequestHistory(Max(FHistorySeconds, Ceil((LastTime - FirstTime) * SecsPerDay) +
          Ceil((Now - LastTime) * SecsPerDay) + 5))
      else
        RequestHistory(FHistorySeconds);
      SendCmd('SUBSCRIBE');
    end;

    FRxLines.Clear;
    if FClient.TakeLines(FRxLines) then
    begin
      FLastRx := Now;
      for i := 0 to FRxLines.Count - 1 do
        HandleLine(FRxLines[i]);
    end;

    if St = csConnected then
    begin
      if (Now - FLastPing) * SecsPerDay >= PingSeconds then
      begin
        SendCmd('PING');
        FLastPing := Now;
      end;
      if (Now - FLastRx) * SecsPerDay > DeadSeconds then
      begin
        FLastError := 'no answer from the server';
        FreeAndNil(FClient);
      end;
    end
    else if St = csDisconnected then
    begin
      FLastError := FClient.ErrorText;
      FreeAndNil(FClient);
    end;

    if (FClient = nil) and FWantConnected then
      FReconnectAt := Now + ReconnectSeconds * OneSecond;
    UpdateConnState;
  end
  else if FWantConnected and FChkReconnect.Checked and (Now >= FReconnectAt) then
    Connect
  else if FWantConnected and not FChkReconnect.Checked then
    Disconnect;

  // live rate
  if (Now - FRateTime) * SecsPerDay >= 2 then
  begin
    FRate := FLiveCount / ((Now - FRateTime) * SecsPerDay);
    FLiveCount := 0;
    FRateTime := Now;
    UpdateStatus;
  end;

  if FDirty then
  begin
    FDirty := False;
    if FChkFollow.Checked then
      SetView(LastTime, True)
    else
    begin
      UpdateScrollBar;
      FPaintBox.Invalidate;
    end;
  end;
end;

procedure TfrmIPCChart.UpdateConnState;
var
  St: TIPCClientState;
begin
  if Assigned(FClient) then St := FClient.State else St := csDisconnected;
  case St of
    csConnected:
      begin
        FShpState.Brush.Color := clLime;
        FLblState.Caption := Format('Connected to %s:%d  %s', [Trim(FEdtHost.Text),
          FSpnPort.Value, FServerInfo]);
      end;
    csConnecting:
      begin
        FShpState.Brush.Color := clYellow;
        FLblState.Caption := Format('Connecting to %s:%d ...', [Trim(FEdtHost.Text), FSpnPort.Value]);
      end;
  else
    FShpState.Brush.Color := clRed;
    if FWantConnected and FChkReconnect.Checked then
      FLblState.Caption := 'Disconnected - retry in ' +
        IntToStr(Max(0, Ceil((FReconnectAt - Now) * SecsPerDay))) + ' s'
    else
      FLblState.Caption := 'Disconnected';
    if FLastError <> '' then
      FLblState.Caption := FLblState.Caption + '  (' + FLastError + ')';
  end;
end;

procedure TfrmIPCChart.SetupSeries(const Header: string);
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
      FCount := 0;      // different set count: old samples do not fit
  finally
    Parts.Free;
  end;
  BuildSeriesMenu;
  AutoAxes;
  FPaintBox.Invalidate;
end;

{ "D <time>;<v1>;..." without the "D " }
function TfrmIPCChart.ParseSample(const S: string; out T: TDateTime;
  out Vals: array of Double): Boolean;
var
  P, Q, i: Integer;
  D: Double;
begin
  Result := False;
  P := Pos(';', S);
  if P = 0 then Exit;
  if not TryStrToFloat(Copy(S, 1, P - 1), D, FS) then Exit;
  T := D;
  for i := 0 to FSeriesCount - 1 do
  begin
    if P > Length(S) then
    begin
      Vals[i] := NaN;
      Continue;
    end;
    Q := PosEx(';', S, P + 1);
    if Q = 0 then Q := Length(S) + 1;
    Vals[i] := ParseValueStr(Copy(S, P + 1, Q - P - 1));
    P := Q;
  end;
  Result := True;
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

procedure TfrmIPCChart.HandleLine(const Line: string);
var
  Cmd, Arg: string;
  P, s, NewCap: Integer;
  T: TDateTime;
  Vals: array[0..MaxSeries - 1] of Double;
begin
  // the most common line first
  if (Length(Line) > 2) and (Line[1] = 'D') and (Line[2] = ' ') then
  begin
    if FSeriesCount = 0 then Exit;
    if not ParseSample(Copy(Line, 3, MaxInt), T, Vals) then Exit;
    if FInHistory then
    begin
      if FHN >= Length(FHT) then
      begin
        NewCap := Max(4096, Length(FHT) * 2);
        SetLength(FHT, NewCap);
        for s := 0 to MaxSeries - 1 do
          SetLength(FHV[s], NewCap);
      end;
      FHT[FHN] := T;
      for s := 0 to FSeriesCount - 1 do
        FHV[s][FHN] := Vals[s];
      Inc(FHN);
    end
    else
    begin
      AddSample(T, Vals);
      Inc(FLiveCount);
      FDirty := True;
    end;
    Exit;
  end;

  P := Pos(' ', Line);
  if P > 0 then
  begin
    Cmd := Copy(Line, 1, P - 1);
    Arg := Copy(Line, P + 1, MaxInt);
  end
  else
  begin
    Cmd := Line;
    Arg := '';
  end;

  if Cmd = 'HELLO' then
    FServerInfo := '(' + Arg + ')'
  else if Cmd = 'INTERVAL' then
    FIntervalMs := StrToIntDef(Arg, 500)
  else if Cmd = 'HEADER' then
    SetupSeries(Arg)
  else if Cmd = 'HISTORY' then
  begin
    FInHistory := True;
    FHN := 0;
    NewCap := Max(16, StrToIntDef(Arg, 0) + 16);
    SetLength(FHT, NewCap);
    for s := 0 to MaxSeries - 1 do
      SetLength(FHV[s], NewCap);
  end
  else if Cmd = 'END' then
    HistoryDone
  else if Cmd = 'RESET' then
  begin
    // the server has new data: start over
    FCount := 0;
    FNoMoreHistory := False;
    RequestHistory(HistorySeconds[Max(0, FCmbHistory.ItemIndex)]);
    FChkFollow.Checked := True;
  end;
  // PONG: nothing to do (FLastRx already updated)
  UpdateConnState;
end;

{ History block complete: it replaces the data; live samples that came
  in meanwhile are newer and stay. }
procedure TfrmIPCChart.HistoryDone;
var
  KeepT: TTimeArray;
  KeepV: TValueArrays;
  KeepN, i, s, First: Integer;
  Vals: array[0..MaxSeries - 1] of Double;
begin
  FInHistory := False;
  FHistPending := False;

  // samples we have that are newer than the history
  First := FCount;
  if FHN > 0 then
    First := LowerBound(FHT[FHN - 1] + OneMillisecond / 2);
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

  FTimes := FHT;
  FData := FHV;
  FCount := FHN;
  FHT := nil;
  for s := 0 to MaxSeries - 1 do
    FHV[s] := nil;
  for i := 0 to KeepN - 1 do
  begin
    for s := 0 to FSeriesCount - 1 do
      Vals[s] := KeepV[s][i];
    AddSample(KeepT[i], Vals);
  end;

  // "All" received, or asked for older data and the oldest sample did not
  // move: the server has nothing older
  if (FCount > 0) and ((FHistorySeconds = 0) or
     (FHistForOlder and (FTimes[0] >= FFirstBefore - OneSecond))) then
    FNoMoreHistory := True;
  FHistForOlder := False;

  AutoAxes;
  if FChkFollow.Checked then
    SetView(LastTime, True)
  else
    SetView(FViewEnd);
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
  s, i: Integer;
  Lo, Hi, V, Pad: Double;
begin
  Lo := Infinity;
  Hi := -Infinity;
  for s := 0 to FSeriesCount - 1 do
    if FSeries[s].Kind <> dkBoolean then
      for i := 0 to FCount - 1 do
      begin
        V := FData[s][i];
        if IsNan(V) then Continue;
        if V < Lo then Lo := V;
        if V > Hi then Hi := V;
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
  if FHistPending or FNoMoreHistory or (FCount = 0) then Exit;
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
    FScrollBar.LargeChange := Max(1, PageSec div 2);
    FScrollBar.SmallChange := Max(1, PageSec div 20);
  finally
    FUpdatingScroll := False;
  end;
end;

procedure TfrmIPCChart.UpdateStatus;
var
  S: string;
begin
  if FCount > 0 then
    S := Format('%d samples  %s - %s', [FCount, FormatDateTime('dd/mm hh:nn:ss', FirstTime),
      FormatDateTime('dd/mm hh:nn:ss', LastTime)])
  else
    S := 'no data';
  S := S + Format('  |  live %.1f/s', [FRate]);
  if Assigned(FClient) then
    S := S + Format('  |  %.1f MB received', [FClient.BytesIn / 1048576]);
  if FHistPending then
    S := S + '  |  requesting history ...'
  else if FNoMoreHistory then
    S := S + '  |  all server history loaded';
  FLblStatus.Caption := S;
  FBtnMore.Enabled := not FHistPending and not FNoMoreHistory and Assigned(FClient);
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

{ ---------- drawing ---------- }

procedure TfrmIPCChart.DrawChart(P: TChartPainter; W, H: Integer);
var
  R: TRect;
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
    if Assigned(FClient) and (FClient.State = csConnected) then Txt := 'Waiting for data ...'
    else Txt := 'Not connected - start HistoryRandomData (IPC server on)';
    P.Text((R.Left + R.Right) / 2, (R.Top + R.Bottom) / 2 - 8, Txt, BGRA(170, 170, 180), taCenter);
    if FSeriesCount = 0 then Exit;
  end;

  // before the oldest received sample
  if (FCount > 0) and (FTimes[0] > TStart) then
  begin
    X := Min(XOf(FTimes[0]), R.Right);
    P.FillRect(R.Left, R.Top, X, R.Bottom, BGRA(255, 255, 255, 10));
    if FHistPending then Txt := 'requesting older data ...'
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
        if s = 0 then
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
    for s := 0 to FSeriesCount - 1 do
    begin
      if not FSeries[s].Visible then Continue;
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

    // hover
    if (FHoverX >= R.Left) and (FHoverX < R.Right) and (FHoverY >= R.Top) and
       (FHoverY <= R.Bottom) and not FDragging and (FAxisDrag < 0) then
    begin
      Idx := NearestIndex(TStart + (FHoverX - R.Left) / PW * Span);
      if (Idx >= 0) and (Abs(FTimes[Idx] - (TStart + (FHoverX - R.Left) / PW * Span)) * SecsPerDay
         <= Max(GapSeconds, SpanSec / PW * 2)) then
      begin
        X := XOf(FTimes[Idx]);
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
      P.Text(R.Left, 28, 'Wheel = zoom time, drag = scroll (older data is requested ' +
        'from the server), drag Y axis = move, wheel on Y axis = zoom, double-click = auto',
        BGRA(120, 124, 132));
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
var
  Bmp: TBGRABitmap;
  P: TBGRAChartPainter;
begin
  if (FPaintBox.Width < 200) or (FPaintBox.Height < 100) then Exit;
  Bmp := TBGRABitmap.Create(FPaintBox.Width, FPaintBox.Height, BackColor);
  P := TBGRAChartPainter.Create(Bmp);
  try
    DrawChart(P, Bmp.Width, Bmp.Height);
    Bmp.Draw(FPaintBox.Canvas, 0, 0, True);
  finally
    P.Free;
    Bmp.Free;
  end;
end;

{ ---------- mouse ---------- }

procedure TfrmIPCChart.PaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  A: Integer;
begin
  if Button <> mbLeft then Exit;
  A := AxisAt(X, Y);
  if A >= 0 then
  begin
    FAxisDrag := A;
    FAxisDragY := Y;
    FAxisDragMin := FSeries[A].AxisMin;
  end
  else if PlotRect.Contains(Point(X, Y)) or (Y > PlotRect.Bottom) then
  begin
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
  if FAxisDrag >= 0 then
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
    else FPaintBox.Cursor := crDefault;
    FPaintBox.Invalidate;
  end;
end;

procedure TfrmIPCChart.PaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  FDragging := False;
  FAxisDrag := -1;
  FPaintBox.Cursor := crDefault;
  FPaintBox.Invalidate;
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

procedure TfrmIPCChart.BtnConnectClick(Sender: TObject);
begin
  if FWantConnected then Disconnect else Connect;
end;

procedure TfrmIPCChart.BtnMoreClick(Sender: TObject);
begin
  if FCount = 0 then Exit;
  NeedHistoryFrom(FirstTime - FViewSpan);
end;

procedure TfrmIPCChart.CmbHistoryChange(Sender: TObject);
var
  Sec: Integer;
begin
  Sec := HistorySeconds[Max(0, FCmbHistory.ItemIndex)];
  FNoMoreHistory := False;
  RequestHistory(Sec);
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

end.
