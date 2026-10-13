unit IPCClientPanel;

{
  Self-contained IPC client panel.

  Owns the connection (TIPCDataClient) and the protocol, and shows / controls:
    - server address, connect / disconnect, auto reconnect, history to load
    - connection details: server, protocol, interval, connected since,
      ping time, data received / sent, live rate, last error
    - topics of the server: subscribe per topic, published by the server,
      samples received, last value
    - protocol log

  The chart only gets events:
    OnConnected   -> ask for history (RequestHistory)
    OnHeader      -> data sets changed ("Time;Name [Type];...")
    OnHistory     -> a complete history block (arrays)
    OnSample      -> one live sample
    OnReset       -> data on the server replaced / topics changed:
                     clear and ask for history again
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, DateUtils, Forms, Controls, Graphics, ExtCtrls, StdCtrls,
  Spin, Grids, IPCData;

type
  TIPCHeaderEvent = procedure(Sender: TObject; const Header: string) of object;
  TIPCHistoryEvent = procedure(Sender: TObject; const T: TIPCTimeArray;
    const V: TIPCValueArrays; N: Integer) of object;
  TIPCSampleEvent = procedure(Sender: TObject; T: TDateTime; const V: array of Double) of object;

  { TIPCClientPanel }

  TIPCClientPanel = class(TPanel)
  private
    // UI
    FEdtHost: TEdit;
    FSpnPort: TSpinEdit;
    FBtnConnect: TButton;
    FChkReconnect: TCheckBox;
    FCmbHistory: TComboBox;
    FShpState: TShape;
    FLblState: TLabel;
    FDetails, FTopics: TStringGrid;
    FBtnAll, FBtnNone: TButton;
    FMemoLog: TMemo;
    FPoll, FSlow: TTimer;
    FUpdating: Boolean;

    // connection
    FClient: TIPCDataClient;
    FWantConnected, FStarted: Boolean;
    FServerInfo, FLastError: string;
    FIntervalMs: Integer;
    FConnectedAt, FReconnectAt, FLastRx, FPingSent: TDateTime;
    FPingMs: Double;
    FPingOpen: Boolean;
    FRxLines: TStringList;
    FLiveCount, FLiveTotal: Int64;
    FRateTime: TDateTime;
    FRate: Double;
    FHistPending: Boolean;
    FHistSeconds: Integer;

    // topics
    FTopicCount: Integer;
    FTopicNames, FTopicKinds, FTopicLast: array[0..IPCMaxTopics - 1] of string;
    FTopicPublished, FSubMask: TIPCTopicMask;
    FTopicSamples: array[0..IPCMaxTopics - 1] of Int64;

    // history block being received
    FInHistory: Boolean;
    FHT: TIPCTimeArray;
    FHV: TIPCValueArrays;
    FHN: Integer;

    FOnConnected, FOnReset, FOnHistoryChoice: TNotifyEvent;
    FOnHeader: TIPCHeaderEvent;
    FOnHistory: TIPCHistoryEvent;
    FOnSample: TIPCSampleEvent;

    procedure BuildUI;
    procedure Log(const S: string);
    procedure PollTick(Sender: TObject);
    procedure SlowTick(Sender: TObject);
    procedure HandleLine(const Line: string);
    procedure ParseHeader(const Header: string);
    function ParseSample(const S: string; out T: TDateTime; out Vals: array of Double): Boolean;
    procedure SendSubscribe;
    procedure UpdateState;
    procedure RefreshDetails;
    procedure RefreshTopics;
    procedure BtnConnectClick(Sender: TObject);
    procedure BtnAllClick(Sender: TObject);
    procedure BtnNoneClick(Sender: TObject);
    procedure CmbHistoryChange(Sender: TObject);
    procedure TopicsCheckboxToggled(Sender: TObject; aCol, aRow: Integer;
      aState: TCheckboxState);
    procedure SubscriptionChanged;
    function GetHost: string;
    procedure SetHost(const AValue: string);
    function GetPort: Integer;
    procedure SetPort(AValue: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Connect;
    procedure Disconnect;
    function Connected: Boolean;
    procedure RequestHistory(Seconds: Integer);
    { seconds chosen in the History box (0 = all) }
    function HistorySeconds: Integer;
    property HistoryPending: Boolean read FHistPending;
    property LastRequestSeconds: Integer read FHistSeconds;
    property ServerInfo: string read FServerInfo;
    property Host: string read GetHost write SetHost;
    property Port: Integer read GetPort write SetPort;
    property LiveRate: Double read FRate;
    property TopicCount: Integer read FTopicCount;
    property OnConnected: TNotifyEvent read FOnConnected write FOnConnected;
    property OnHeader: TIPCHeaderEvent read FOnHeader write FOnHeader;
    property OnHistory: TIPCHistoryEvent read FOnHistory write FOnHistory;
    property OnSample: TIPCSampleEvent read FOnSample write FOnSample;
    property OnReset: TNotifyEvent read FOnReset write FOnReset;
    property OnHistoryChoice: TNotifyEvent read FOnHistoryChoice write FOnHistoryChoice;
  end;

implementation

const
  ReconnectSeconds = 3;
  PingSeconds = 5;
  DeadSeconds = 15;
  HistorySecondsList: array[0..6] of Integer = (600, 3600, 10800, 43200, 86400, 259200, 0);
  HistoryNames: array[0..6] of string = ('10 min', '1 hour', '3 hours', '12 hours',
    '1 day', '3 days', 'All');
  DefaultHistoryIndex = 2;
  DetailNames: array[0..9] of string = ('Server', 'Protocol', 'Sample interval',
    'Connected since', 'Ping (round trip)', 'Received', 'Sent', 'Live samples',
    'History', 'Last error');

var
  FS: TFormatSettings;

function FormatBytes(B: Int64): string;
begin
  if B >= 1048576 then Result := Format('%.1f MB', [B / 1048576])
  else if B >= 1024 then Result := Format('%.1f kB', [B / 1024])
  else Result := IntToStr(B) + ' B';
end;

function ParseValueStr(const S: string): Double;
begin
  if S = '' then Result := NaN
  else if SameText(S, 'TRUE') then Result := 1
  else if SameText(S, 'FALSE') then Result := 0
  else if not TryStrToFloat(Trim(S), Result, FS) then Result := NaN;
end;

{ TIPCClientPanel }

constructor TIPCClientPanel.Create(AOwner: TComponent);
var
  i: Integer;
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  FRxLines := TStringList.Create;
  FIntervalMs := 500;
  for i := 0 to IPCMaxTopics - 1 do
  begin
    FSubMask[i] := True;
    FTopicPublished[i] := True;
  end;
  BuildUI;
  FPoll := TTimer.Create(Self);
  FPoll.Interval := 100;
  FPoll.OnTimer := @PollTick;
  FPoll.Enabled := True;
  FSlow := TTimer.Create(Self);
  FSlow.Interval := 1000;
  FSlow.OnTimer := @SlowTick;
  FSlow.Enabled := True;
end;

destructor TIPCClientPanel.Destroy;
begin
  FPoll.Enabled := False;
  FSlow.Enabled := False;
  FreeAndNil(FClient);
  FRxLines.Free;
  inherited Destroy;
end;

procedure TIPCClientPanel.BuildUI;
var
  GB: TGroupBox;
  Bar: TPanel;
  Lbl: TLabel;
  Col: TGridColumn;
  i: Integer;

  function AddCol(G: TStringGrid; const ATitle: string; AWidth: Integer;
    AAlign: TAlignment = taLeftJustify): TGridColumn;
  begin
    Result := G.Columns.Add;
    Result.Title.Caption := ATitle;
    Result.Width := AWidth;
    Result.Alignment := AAlign;
    Result.ReadOnly := True;
  end;

  function NewGrid(AParent: TWinControl): TStringGrid;
  begin
    Result := TStringGrid.Create(Self);
    Result.Parent := AParent;
    Result.Align := alClient;
    Result.FixedCols := 0;
    Result.RowCount := 1;
    Result.DefaultRowHeight := 21;
    Result.Options := Result.Options + [goColSizing] - [goRangeSelect];
  end;

begin
  // --- connection ---
  GB := TGroupBox.Create(Self);
  GB.Parent := Self;
  GB.Align := alTop;
  GB.Height := 116;
  GB.Caption := ' Connection ';

  Lbl := TLabel.Create(Self);
  Lbl.Parent := GB;
  Lbl.SetBounds(8, 8, 44, 18);
  Lbl.Caption := 'Server';
  FEdtHost := TEdit.Create(Self);
  FEdtHost.Parent := GB;
  FEdtHost.SetBounds(54, 4, 110, 24);
  FEdtHost.Text := '127.0.0.1';
  Lbl := TLabel.Create(Self);
  Lbl.Parent := GB;
  Lbl.SetBounds(172, 8, 30, 18);
  Lbl.Caption := 'Port';
  FSpnPort := TSpinEdit.Create(Self);
  FSpnPort.Parent := GB;
  FSpnPort.SetBounds(204, 4, 76, 24);
  FSpnPort.MinValue := 1;
  FSpnPort.MaxValue := 65535;
  FSpnPort.Value := IPCDefaultPort;

  FBtnConnect := TButton.Create(Self);
  FBtnConnect.Parent := GB;
  FBtnConnect.SetBounds(8, 34, 100, 26);
  FBtnConnect.Caption := 'Connect';
  FBtnConnect.OnClick := @BtnConnectClick;
  FChkReconnect := TCheckBox.Create(Self);
  FChkReconnect.Parent := GB;
  FChkReconnect.SetBounds(116, 38, 120, 20);
  FChkReconnect.Caption := 'Auto reconnect';
  FChkReconnect.Checked := True;

  Lbl := TLabel.Create(Self);
  Lbl.Parent := GB;
  Lbl.SetBounds(244, 38, 44, 18);
  Lbl.Caption := 'History';
  FCmbHistory := TComboBox.Create(Self);
  FCmbHistory.Parent := GB;
  FCmbHistory.SetBounds(292, 34, 80, 24);
  FCmbHistory.Style := csDropDownList;
  for i := Low(HistoryNames) to High(HistoryNames) do
    FCmbHistory.Items.Add(HistoryNames[i]);
  FCmbHistory.ItemIndex := DefaultHistoryIndex;
  FCmbHistory.Hint := 'History loaded when connecting';
  FCmbHistory.ShowHint := True;
  FCmbHistory.OnChange := @CmbHistoryChange;

  FShpState := TShape.Create(Self);
  FShpState.Parent := GB;
  FShpState.Shape := stCircle;
  FShpState.SetBounds(8, 70, 14, 14);
  FLblState := TLabel.Create(Self);
  FLblState.Parent := GB;
  FLblState.SetBounds(28, 69, 360, 18);

  // --- details ---
  GB := TGroupBox.Create(Self);
  GB.Parent := Self;
  GB.Align := alTop;
  GB.Top := 1000;
  GB.Height := 252;
  GB.Caption := ' Connection details ';
  FDetails := NewGrid(GB);
  FDetails.Options := FDetails.Options + [goRowSelect];
  AddCol(FDetails, 'Property', 130);
  AddCol(FDetails, 'Value', 240);
  FDetails.RowCount := 1 + Length(DetailNames);
  for i := 0 to High(DetailNames) do
    FDetails.Cells[0, i + 1] := DetailNames[i];

  // --- topics ---
  GB := TGroupBox.Create(Self);
  GB.Parent := Self;
  GB.Align := alTop;
  GB.Top := 2000;
  GB.Height := 200;
  GB.Caption := ' Topics - tick to subscribe ';
  Bar := TPanel.Create(Self);
  Bar.Parent := GB;
  Bar.Align := alBottom;
  Bar.Height := 32;
  Bar.BevelOuter := bvNone;
  FBtnAll := TButton.Create(Self);
  FBtnAll.Parent := Bar;
  FBtnAll.SetBounds(4, 3, 80, 26);
  FBtnAll.Caption := 'All';
  FBtnAll.OnClick := @BtnAllClick;
  FBtnNone := TButton.Create(Self);
  FBtnNone.Parent := Bar;
  FBtnNone.SetBounds(90, 3, 80, 26);
  FBtnNone.Caption := 'None';
  FBtnNone.OnClick := @BtnNoneClick;
  FTopics := NewGrid(GB);
  FTopics.Options := FTopics.Options + [goEditing];
  Col := FTopics.Columns.Add;
  Col.Title.Caption := 'Sub';
  Col.Width := 36;
  Col.ButtonStyle := cbsCheckboxColumn;
  Col.ValueChecked := '1';
  Col.ValueUnchecked := '0';
  AddCol(FTopics, '#', 24, taRightJustify);
  AddCol(FTopics, 'Topic', 130);
  AddCol(FTopics, 'Type', 58);
  AddCol(FTopics, 'Server', 52);
  AddCol(FTopics, 'Samples', 64, taRightJustify);
  AddCol(FTopics, 'Last', 64, taRightJustify);
  FTopics.OnCheckboxToggled := @TopicsCheckboxToggled;

  // --- log ---
  GB := TGroupBox.Create(Self);
  GB.Parent := Self;
  GB.Align := alClient;
  GB.Caption := ' Protocol log (samples not shown) ';
  FMemoLog := TMemo.Create(Self);
  FMemoLog.Parent := GB;
  FMemoLog.Align := alClient;
  FMemoLog.ReadOnly := True;
  FMemoLog.ScrollBars := ssAutoVertical;
  FMemoLog.Font.Name := 'Consolas';
  FMemoLog.Font.Size := 9;
end;

procedure TIPCClientPanel.Log(const S: string);
begin
  FMemoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
  while FMemoLog.Lines.Count > IPCMaxLog do
    FMemoLog.Lines.Delete(0);
  FMemoLog.SelStart := Length(FMemoLog.Text);
end;

{ ---------- connection ---------- }

procedure TIPCClientPanel.Connect;
begin
  FreeAndNil(FClient);
  FWantConnected := True;
  FStarted := False;
  FHistPending := False;
  FInHistory := False;
  FLastError := '';
  FServerInfo := '';
  FPingOpen := False;
  FPingMs := -1;
  Log(Format('connecting to %s:%d', [Trim(FEdtHost.Text), FSpnPort.Value]));
  FClient := TIPCDataClient.Create(Trim(FEdtHost.Text), FSpnPort.Value);
  FLastRx := Now;
  FBtnConnect.Caption := 'Disconnect';
  FEdtHost.Enabled := False;
  FSpnPort.Enabled := False;
  UpdateState;
end;

procedure TIPCClientPanel.Disconnect;
begin
  FWantConnected := False;
  if Assigned(FClient) then Log('disconnected');
  FreeAndNil(FClient);
  FHistPending := False;
  FBtnConnect.Caption := 'Connect';
  FEdtHost.Enabled := True;
  FSpnPort.Enabled := True;
  UpdateState;
end;

function TIPCClientPanel.Connected: Boolean;
begin
  Result := Assigned(FClient) and (FClient.State = csConnected);
end;

procedure TIPCClientPanel.RequestHistory(Seconds: Integer);
begin
  if not Connected then Exit;
  FHistSeconds := Seconds;
  FHistPending := True;
  FClient.Send('HISTORY ' + IntToStr(Seconds));
  Log('< HISTORY ' + IntToStr(Seconds));
  RefreshDetails;
end;

function TIPCClientPanel.HistorySeconds: Integer;
begin
  Result := HistorySecondsList[Max(0, FCmbHistory.ItemIndex)];
end;

{ SUBSCRIBE with the ticked topics (or UNSUBSCRIBE when none) }
procedure TIPCClientPanel.SendSubscribe;
var
  i, n: Integer;
  L: string;
begin
  if not Connected then Exit;
  L := '';
  n := 0;
  for i := 0 to Max(FTopicCount, 1) - 1 do
    if FSubMask[i] then
    begin
      if L <> '' then L := L + ',';
      L := L + IntToStr(i + 1);
      Inc(n);
    end;
  if FTopicCount = 0 then L := 'SUBSCRIBE'
  else if n = FTopicCount then L := 'SUBSCRIBE'
  else if n = 0 then L := 'UNSUBSCRIBE'
  else L := 'SUBSCRIBE ' + L;
  FClient.Send(L);
  Log('< ' + L);
end;

procedure TIPCClientPanel.PollTick(Sender: TObject);
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
      FConnectedAt := Now;
      FLastRx := Now;
      FPingSent := Now;
      Log('connected');
      // topics first: the server filters the history with them
      SendSubscribe;
      // then the chart asks for the history it needs
      if Assigned(FOnConnected) then FOnConnected(Self);
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
      if not FPingOpen and ((Now - FPingSent) * SecsPerDay >= PingSeconds) then
      begin
        FClient.Send('PING');
        FPingSent := Now;
        FPingOpen := True;
      end;
      if (Now - FLastRx) * SecsPerDay > DeadSeconds then
      begin
        FLastError := 'no answer from the server';
        Log('error: ' + FLastError);
        FreeAndNil(FClient);
      end;
    end
    else if St = csDisconnected then
    begin
      FLastError := FClient.ErrorText;
      Log('connection lost: ' + FLastError);
      FreeAndNil(FClient);
    end;

    if (FClient = nil) and FWantConnected then
    begin
      FReconnectAt := Now + ReconnectSeconds * OneSecond;
      FHistPending := False;
      FInHistory := False;
    end;
  end
  else if FWantConnected and FChkReconnect.Checked and (Now >= FReconnectAt) then
    Connect
  else if FWantConnected and not FChkReconnect.Checked then
    Disconnect;
end;

procedure TIPCClientPanel.SlowTick(Sender: TObject);
begin
  if (Now - FRateTime) * SecsPerDay >= 1.9 then
  begin
    if FRateTime > 0 then
      FRate := FLiveCount / ((Now - FRateTime) * SecsPerDay);
    FLiveCount := 0;
    FRateTime := Now;
  end;
  UpdateState;
  RefreshDetails;
  RefreshTopics;
end;

procedure TIPCClientPanel.ParseHeader(const Header: string);
var
  Parts: TStringList;
  i, P: Integer;
  F: string;
begin
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Header;
    FTopicCount := Min(IPCMaxTopics, Parts.Count - 1);
    for i := 0 to FTopicCount - 1 do
    begin
      F := Trim(Parts[i + 1]);
      P := LastDelimiter('[', F);
      if (P > 0) and (F[Length(F)] = ']') then
      begin
        FTopicNames[i] := Trim(Copy(F, 1, P - 1));
        FTopicKinds[i] := Copy(F, P + 1, Length(F) - P - 1);
      end
      else
      begin
        FTopicNames[i] := F;
        FTopicKinds[i] := 'Double';
      end;
    end;
  finally
    Parts.Free;
  end;
end;

function TIPCClientPanel.ParseSample(const S: string; out T: TDateTime;
  out Vals: array of Double): Boolean;
var
  P, Q, i: Integer;
  D: Double;
  F: string;
begin
  Result := False;
  P := Pos(';', S);
  if P = 0 then Exit;
  if not TryStrToFloat(Copy(S, 1, P - 1), D, FS) then Exit;
  T := D;
  for i := 0 to FTopicCount - 1 do
  begin
    if P > Length(S) then
    begin
      Vals[i] := NaN;
      Continue;
    end;
    Q := PosEx(';', S, P + 1);
    if Q = 0 then Q := Length(S) + 1;
    F := Copy(S, P + 1, Q - P - 1);
    Vals[i] := ParseValueStr(F);
    if F <> '' then FTopicLast[i] := F;
    P := Q;
  end;
  Result := True;
end;

procedure TIPCClientPanel.HandleLine(const Line: string);
var
  Cmd, Arg: string;
  P, s, NewCap, i: Integer;
  T: TDateTime;
  Vals: array[0..IPCMaxTopics - 1] of Double;
  Parts: TStringList;
begin
  // the most common line first
  if (Length(Line) > 2) and (Line[1] = 'D') and (Line[2] = ' ') then
  begin
    if FTopicCount = 0 then Exit;
    if not ParseSample(Copy(Line, 3, MaxInt), T, Vals) then Exit;
    for s := 0 to FTopicCount - 1 do
      if not IsNan(Vals[s]) then Inc(FTopicSamples[s]);
    if FInHistory then
    begin
      if FHN >= Length(FHT) then
      begin
        NewCap := Max(4096, Length(FHT) * 2);
        SetLength(FHT, NewCap);
        for s := 0 to IPCMaxTopics - 1 do
          SetLength(FHV[s], NewCap);
      end;
      FHT[FHN] := T;
      for s := 0 to FTopicCount - 1 do
        FHV[s][FHN] := Vals[s];
      Inc(FHN);
    end
    else
    begin
      Inc(FLiveCount);
      Inc(FLiveTotal);
      if Assigned(FOnSample) then FOnSample(Self, T, Vals);
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

  if Cmd = 'PONG' then
  begin
    FPingMs := (Now - FPingSent) * MSecsPerDay;
    FPingOpen := False;
    Exit;                      // not logged (every 5 s)
  end;
  if Cmd <> 'TOPIC' then
    Log('> ' + Line);

  if Cmd = 'HELLO' then
    FServerInfo := Arg
  else if Cmd = 'INTERVAL' then
    FIntervalMs := StrToIntDef(Arg, 500)
  else if Cmd = 'HEADER' then
  begin
    ParseHeader(Arg);
    if Assigned(FOnHeader) then FOnHeader(Self, Arg);
  end
  else if Cmd = 'TOPIC' then
  begin
    // TOPIC <i>;<name>;<type>;<published>
    Parts := TStringList.Create;
    try
      Parts.Delimiter := ';';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := Arg;
      if Parts.Count >= 4 then
      begin
        i := StrToIntDef(Parts[0], 0) - 1;
        if (i >= 0) and (i < IPCMaxTopics) then
        begin
          FTopicNames[i] := Parts[1];
          FTopicKinds[i] := Parts[2];
          FTopicPublished[i] := Parts[3] = '1';
        end;
      end;
    finally
      Parts.Free;
    end;
    RefreshTopics;
  end
  else if Cmd = 'HISTORY' then
  begin
    FInHistory := True;
    FHN := 0;
    NewCap := Max(16, StrToIntDef(Arg, 0) + 16);
    SetLength(FHT, NewCap);
    for s := 0 to IPCMaxTopics - 1 do
      SetLength(FHV[s], NewCap);
  end
  else if Cmd = 'END' then
  begin
    FInHistory := False;
    FHistPending := False;
    if Assigned(FOnHistory) then FOnHistory(Self, FHT, FHV, FHN);
    FHT := nil;
    for s := 0 to IPCMaxTopics - 1 do
      FHV[s] := nil;
  end
  else if Cmd = 'RESET' then
  begin
    if Assigned(FOnReset) then FOnReset(Self);
  end;
  UpdateState;
end;

{ ---------- topics ---------- }

procedure TIPCClientPanel.SubscriptionChanged;
begin
  SendSubscribe;
  // the history has to be loaded again with the new topics
  if Assigned(FOnReset) then FOnReset(Self);
  RefreshTopics;
end;

procedure TIPCClientPanel.TopicsCheckboxToggled(Sender: TObject; aCol, aRow: Integer;
  aState: TCheckboxState);
begin
  if FUpdating or (aRow < 1) or (aRow > IPCMaxTopics) then Exit;
  FSubMask[aRow - 1] := aState = cbChecked;
  SubscriptionChanged;
end;

procedure TIPCClientPanel.BtnAllClick(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to IPCMaxTopics - 1 do FSubMask[i] := True;
  SubscriptionChanged;
end;

procedure TIPCClientPanel.BtnNoneClick(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to IPCMaxTopics - 1 do FSubMask[i] := False;
  SubscriptionChanged;
end;

procedure TIPCClientPanel.RefreshTopics;
var
  i: Integer;
begin
  FUpdating := True;
  try
    FTopics.RowCount := 1 + FTopicCount;
    for i := 0 to FTopicCount - 1 do
    begin
      FTopics.Cells[0, i + 1] := IntToStr(Ord(FSubMask[i]));
      FTopics.Cells[1, i + 1] := IntToStr(i + 1);
      FTopics.Cells[2, i + 1] := FTopicNames[i];
      FTopics.Cells[3, i + 1] := FTopicKinds[i];
      if FTopicPublished[i] then FTopics.Cells[4, i + 1] := 'yes'
      else FTopics.Cells[4, i + 1] := 'off';
      FTopics.Cells[5, i + 1] := IntToStr(FTopicSamples[i]);
      FTopics.Cells[6, i + 1] := FTopicLast[i];
    end;
  finally
    FUpdating := False;
  end;
end;

{ ---------- display ---------- }

procedure TIPCClientPanel.UpdateState;
var
  St: TIPCClientState;
begin
  if Assigned(FClient) then St := FClient.State else St := csDisconnected;
  case St of
    csConnected:
      begin
        FShpState.Brush.Color := clLime;
        FLblState.Caption := Format('Connected to %s:%d', [Trim(FEdtHost.Text), FSpnPort.Value]);
      end;
    csConnecting:
      begin
        FShpState.Brush.Color := clYellow;
        FLblState.Caption := 'Connecting ...';
      end;
  else
    FShpState.Brush.Color := clRed;
    if FWantConnected and FChkReconnect.Checked then
      FLblState.Caption := 'Disconnected - retry in ' +
        IntToStr(Max(0, Ceil((FReconnectAt - Now) * SecsPerDay))) + ' s'
    else
      FLblState.Caption := 'Disconnected';
  end;
end;

procedure TIPCClientPanel.RefreshDetails;
var
  V: array[0..9] of string;
  i: Integer;
  P: Integer;
begin
  for i := 0 to High(V) do V[i] := '-';
  if FServerInfo <> '' then
  begin
    P := RPos(' ', FServerInfo);
    if P > 0 then
    begin
      V[0] := Copy(FServerInfo, 1, P - 1);
      V[1] := 'v' + Copy(FServerInfo, P + 1, MaxInt) + Format(' (client v%d)', [IPCProtocolVersion]);
    end
    else
      V[0] := FServerInfo;
  end;
  V[2] := IntToStr(FIntervalMs) + ' ms';
  if Connected then
  begin
    V[3] := FormatDateTime('dd/mm hh:nn:ss', FConnectedAt);
    if FPingMs >= 0 then V[4] := Format('%.1f ms', [FPingMs]);
    V[5] := FormatBytes(FClient.BytesIn);
    V[6] := FormatBytes(FClient.BytesOut);
  end;
  V[7] := Format('%.1f /s  (%d total)', [FRate, FLiveTotal]);
  if FHistPending then
    V[8] := 'requested ' + IntToStr(FHistSeconds) + ' s ...'
  else if FHistSeconds > 0 then
    V[8] := 'last request ' + IntToStr(FHistSeconds) + ' s'
  else
    V[8] := 'last request: all';
  if FLastError <> '' then V[9] := FLastError;
  for i := 0 to High(V) do
    FDetails.Cells[1, i + 1] := V[i];
end;

{ ---------- controls ---------- }

function TIPCClientPanel.GetHost: string;
begin
  Result := Trim(FEdtHost.Text);
end;

procedure TIPCClientPanel.SetHost(const AValue: string);
begin
  FEdtHost.Text := AValue;
end;

function TIPCClientPanel.GetPort: Integer;
begin
  Result := FSpnPort.Value;
end;

procedure TIPCClientPanel.SetPort(AValue: Integer);
begin
  FSpnPort.Value := AValue;
end;

procedure TIPCClientPanel.BtnConnectClick(Sender: TObject);
begin
  if FWantConnected then Disconnect else Connect;
end;

procedure TIPCClientPanel.CmbHistoryChange(Sender: TObject);
begin
  if Assigned(FOnHistoryChoice) then FOnHistoryChoice(Self);
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
end.
