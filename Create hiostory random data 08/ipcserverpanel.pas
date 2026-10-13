unit IPCServerPanel;

{
  Self-contained IPC server panel.

  Owns the TIPCDataServer and shows / controls everything about it:
    - start / stop, port, network access, status and totals
    - topics (one per data set): publish on/off, subscribers, samples
      sent, last value
    - connected clients: address, since, live, topics, samples / data sent,
      last command; disconnect one or all
    - activity log

  The host (HistoryRandomData) only supplies data:
    Server.OnGetHeader / Server.OnGetHistory, Server.SetHeader(...) when
    the data sets change, Server.Publish(...) for new samples and
    OnGetLastValues for the "last value" column.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, ExtCtrls, StdCtrls, Spin,
  Grids, IPCData;

type
  { "v1;v2;..." of the newest sample, as shown to the user }
  TIPCLastValuesFunc = function: string of object;

  { TIPCServerPanel }

  TIPCServerPanel = class(TPanel)
  private
    FServer: TIPCDataServer;
    FBtnStart: TButton;
    FSpnPort: TSpinEdit;
    FChkAll: TCheckBox;
    FShpState: TShape;
    FLblState, FLblTotals: TLabel;
    FTopics, FClients: TStringGrid;
    FBtnKick, FBtnKickAll, FBtnClearLog: TButton;
    FMemoLog: TMemo;
    FTimer: TTimer;
    FUpdating: Boolean;
    FOnGetLastValues: TIPCLastValuesFunc;
    procedure BuildUI;
    procedure BtnStartClick(Sender: TObject);
    procedure BtnKickClick(Sender: TObject);
    procedure BtnKickAllClick(Sender: TObject);
    procedure BtnClearLogClick(Sender: TObject);
    procedure TopicsCheckboxToggled(Sender: TObject; aCol, aRow: Integer;
      aState: TCheckboxState);
    procedure ServerChange(Sender: TObject);
    procedure TimerTick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure StartServer;
    procedure StopServer;
    procedure RefreshView;
    property Server: TIPCDataServer read FServer;
    property OnGetLastValues: TIPCLastValuesFunc read FOnGetLastValues write FOnGetLastValues;
  end;

implementation

function FormatBytes(B: Int64): string;
begin
  if B >= 1048576 then Result := Format('%.1f MB', [B / 1048576])
  else if B >= 1024 then Result := Format('%.1f kB', [B / 1024])
  else Result := IntToStr(B) + ' B';
end;

function FormatUptime(D: TDateTime): string;
var
  Days: Integer;
begin
  Days := Trunc(D);
  Result := FormatDateTime('hh:nn:ss', D);
  if Days > 0 then Result := IntToStr(Days) + 'd ' + Result;
end;

{ TIPCServerPanel }

constructor TIPCServerPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  FServer := TIPCDataServer.Create;
  FServer.OnChange := @ServerChange;
  BuildUI;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 1000;
  FTimer.OnTimer := @TimerTick;
  FTimer.Enabled := True;
end;

destructor TIPCServerPanel.Destroy;
begin
  FTimer.Enabled := False;
  FreeAndNil(FServer);
  inherited Destroy;
end;

procedure TIPCServerPanel.BuildUI;
var
  TopBar, Grp: TPanel;
  Lbl: TLabel;
  Split: TSplitter;
  GB: TGroupBox;
  Col: TGridColumn;

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
    Result.DefaultRowHeight := 22;
    Result.Options := Result.Options + [goRowSelect, goColSizing] - [goRangeSelect];
  end;

begin
  // --- server controls ---
  TopBar := TPanel.Create(Self);
  TopBar.Parent := Self;
  TopBar.Align := alTop;
  TopBar.Top := 0;          // alTop controls are stacked by Top
  TopBar.Height := 66;
  TopBar.BevelOuter := bvNone;

  FBtnStart := TButton.Create(Self);
  FBtnStart.Parent := TopBar;
  FBtnStart.SetBounds(8, 6, 90, 26);
  FBtnStart.Caption := 'Start';
  FBtnStart.OnClick := @BtnStartClick;

  Lbl := TLabel.Create(Self);
  Lbl.Parent := TopBar;
  Lbl.SetBounds(110, 11, 30, 18);
  Lbl.Caption := 'Port';

  FSpnPort := TSpinEdit.Create(Self);
  FSpnPort.Parent := TopBar;
  FSpnPort.SetBounds(140, 7, 76, 24);
  FSpnPort.MinValue := 1024;
  FSpnPort.MaxValue := 65535;
  FSpnPort.Value := IPCDefaultPort;

  FChkAll := TCheckBox.Create(Self);
  FChkAll.Parent := TopBar;
  FChkAll.SetBounds(228, 10, 160, 20);
  FChkAll.Caption := 'Allow other computers';
  FChkAll.Hint := 'Off: only programs on this PC (127.0.0.1)' + LineEnding +
    'On: listen on all network interfaces';
  FChkAll.ShowHint := True;

  FShpState := TShape.Create(Self);
  FShpState.Parent := TopBar;
  FShpState.Shape := stCircle;
  FShpState.SetBounds(396, 12, 14, 14);

  FLblState := TLabel.Create(Self);
  FLblState.Parent := TopBar;
  FLblState.SetBounds(416, 11, 500, 18);

  FLblTotals := TLabel.Create(Self);
  FLblTotals.Parent := TopBar;
  FLblTotals.SetBounds(8, 42, 900, 18);
  FLblTotals.Font.Color := clGrayText;

  // --- topics ---
  GB := TGroupBox.Create(Self);
  GB.Parent := Self;
  GB.Align := alTop;
  GB.Top := 100;
  GB.Height := 170;
  GB.Caption := ' Topics (one per data set) - untick "Publish" to stop sending a topic ';
  FTopics := NewGrid(GB);
  FTopics.Options := FTopics.Options + [goEditing] - [goRowSelect];
  Col := FTopics.Columns.Add;
  Col.Title.Caption := 'Publish';
  Col.Width := 60;
  Col.ButtonStyle := cbsCheckboxColumn;
  Col.ValueChecked := '1';
  Col.ValueUnchecked := '0';
  AddCol(FTopics, '#', 30, taRightJustify);
  AddCol(FTopics, 'Topic', 190);
  AddCol(FTopics, 'Type', 70);
  AddCol(FTopics, 'Subscribers', 80, taRightJustify);
  AddCol(FTopics, 'Live samples', 100, taRightJustify);
  AddCol(FTopics, 'Last value', 100, taRightJustify);
  FTopics.OnCheckboxToggled := @TopicsCheckboxToggled;

  // --- clients ---
  GB := TGroupBox.Create(Self);
  GB.Parent := Self;
  GB.Align := alTop;
  GB.Top := 1000;
  GB.Height := 190;
  GB.Caption := ' Connected clients ';
  Grp := TPanel.Create(Self);
  Grp.Parent := GB;
  Grp.Align := alBottom;
  Grp.Height := 34;
  Grp.BevelOuter := bvNone;
  FBtnKick := TButton.Create(Self);
  FBtnKick.Parent := Grp;
  FBtnKick.SetBounds(4, 4, 140, 26);
  FBtnKick.Caption := 'Disconnect client';
  FBtnKick.OnClick := @BtnKickClick;
  FBtnKickAll := TButton.Create(Self);
  FBtnKickAll.Parent := Grp;
  FBtnKickAll.SetBounds(150, 4, 110, 26);
  FBtnKickAll.Caption := 'Disconnect all';
  FBtnKickAll.OnClick := @BtnKickAllClick;
  FClients := NewGrid(GB);
  AddCol(FClients, 'Id', 34, taRightJustify);
  AddCol(FClients, 'Client', 130);
  AddCol(FClients, 'Connected', 80);
  AddCol(FClients, 'Live', 40);
  AddCol(FClients, 'Topics', 60);
  AddCol(FClients, 'Samples sent', 95, taRightJustify);
  AddCol(FClients, 'Data sent', 80, taRightJustify);
  AddCol(FClients, 'Last command', 160);

  Split := TSplitter.Create(Self);
  Split.Parent := Self;
  Split.Align := alTop;
  Split.Top := 2000;

  // --- log ---
  GB := TGroupBox.Create(Self);
  GB.Parent := Self;
  GB.Align := alClient;
  GB.Caption := ' Activity log ';
  Grp := TPanel.Create(Self);
  Grp.Parent := GB;
  Grp.Align := alBottom;
  Grp.Height := 34;
  Grp.BevelOuter := bvNone;
  FBtnClearLog := TButton.Create(Self);
  FBtnClearLog.Parent := Grp;
  FBtnClearLog.SetBounds(4, 4, 90, 26);
  FBtnClearLog.Caption := 'Clear log';
  FBtnClearLog.OnClick := @BtnClearLogClick;
  FMemoLog := TMemo.Create(Self);
  FMemoLog.Parent := GB;
  FMemoLog.Align := alClient;
  FMemoLog.ReadOnly := True;
  FMemoLog.ScrollBars := ssAutoVertical;
  FMemoLog.Font.Name := 'Consolas';
  FMemoLog.Font.Size := 9;
end;

procedure TIPCServerPanel.StartServer;
begin
  FServer.Stop;
  FServer.Port := FSpnPort.Value;
  FServer.AllInterfaces := FChkAll.Checked;
  FServer.Start;
  RefreshView;
end;

procedure TIPCServerPanel.StopServer;
begin
  Screen.Cursor := crHourGlass;
  try
    FServer.Stop;
  finally
    Screen.Cursor := crDefault;
  end;
  RefreshView;
end;

procedure TIPCServerPanel.BtnStartClick(Sender: TObject);
begin
  if FServer.Active then StopServer else StartServer;
end;

procedure TIPCServerPanel.BtnKickClick(Sender: TObject);
var
  Id: Integer;
begin
  if (FClients.Row < 1) or (FClients.Row >= FClients.RowCount) then Exit;
  Id := StrToIntDef(FClients.Cells[0, FClients.Row], -1);
  if Id >= 0 then FServer.KickClient(Id);
end;

procedure TIPCServerPanel.BtnKickAllClick(Sender: TObject);
begin
  FServer.KickAll;
end;

procedure TIPCServerPanel.BtnClearLogClick(Sender: TObject);
begin
  FMemoLog.Clear;
end;

procedure TIPCServerPanel.TopicsCheckboxToggled(Sender: TObject; aCol, aRow: Integer;
  aState: TCheckboxState);
begin
  if FUpdating or (aRow < 1) then Exit;
  FServer.SetTopicEnabled(aRow - 1, aState = cbChecked);
end;

procedure TIPCServerPanel.ServerChange(Sender: TObject);
begin
  RefreshView;
end;

procedure TIPCServerPanel.TimerTick(Sender: TObject);
begin
  RefreshView;
end;

procedure TIPCServerPanel.RefreshView;
var
  Infos: TIPCClientInfos;
  i, n, Live, SelId, SelRow: Integer;
  Last: TStringList;
  Log: TStringList;
  Host: string;
begin
  if FServer = nil then Exit;
  FUpdating := True;
  try
    // state
    FSpnPort.Enabled := not FServer.Active;
    FChkAll.Enabled := not FServer.Active;
    if FServer.Active then
    begin
      FBtnStart.Caption := 'Stop';
      FShpState.Brush.Color := clLime;
      if FServer.AllInterfaces then Host := 'all interfaces' else Host := '127.0.0.1';
      FLblState.Caption := Format('Running on %s, port %d, protocol v%d, interval %d ms',
        [Host, FServer.Port, IPCProtocolVersion, FServer.IntervalMs]);
    end
    else
    begin
      FBtnStart.Caption := 'Start';
      FShpState.Brush.Color := clRed;
      if FServer.LastError <> '' then
        FLblState.Caption := 'Stopped - ' + FServer.LastError
      else
        FLblState.Caption := 'Stopped';
    end;

    Infos := FServer.ClientInfos;
    Live := 0;
    for i := 0 to High(Infos) do
      if Infos[i].Live then Inc(Live);
    if FServer.Active then
      FLblTotals.Caption := Format('Clients: %d (%d live)   |   Data sent: %s   |   Up: %s',
        [Length(Infos), Live, FormatBytes(FServer.BytesTotal), FormatUptime(Now - FServer.StartedAt)])
    else
      FLblTotals.Caption := Format('Data sent: %s', [FormatBytes(FServer.BytesTotal)]);

    // topics
    Last := TStringList.Create;
    try
      Last.Delimiter := ';';
      Last.StrictDelimiter := True;
      if Assigned(FOnGetLastValues) then
        Last.DelimitedText := FOnGetLastValues();
      n := FServer.TopicCount;
      FTopics.RowCount := 1 + n;
      for i := 0 to n - 1 do
      begin
        FTopics.Cells[0, i + 1] := IntToStr(Ord(FServer.TopicEnabled(i)));
        FTopics.Cells[1, i + 1] := IntToStr(i + 1);
        FTopics.Cells[2, i + 1] := FServer.TopicName(i);
        FTopics.Cells[3, i + 1] := FServer.TopicKind(i);
        FTopics.Cells[4, i + 1] := IntToStr(FServer.TopicSubscribers(i));
        FTopics.Cells[5, i + 1] := IntToStr(FServer.TopicSamples(i));
        if i < Last.Count then
          FTopics.Cells[6, i + 1] := Last[i]
        else
          FTopics.Cells[6, i + 1] := '';
      end;
    finally
      Last.Free;
    end;

    // clients (keep the selection on the same client)
    SelId := -1;
    if (FClients.Row >= 1) and (FClients.Row < FClients.RowCount) then
      SelId := StrToIntDef(FClients.Cells[0, FClients.Row], -1);
    FClients.RowCount := 1 + Length(Infos);
    SelRow := -1;
    for i := 0 to High(Infos) do
      with Infos[i] do
      begin
        FClients.Cells[0, i + 1] := IntToStr(Id);
        FClients.Cells[1, i + 1] := Peer;
        FClients.Cells[2, i + 1] := FormatDateTime('hh:nn:ss', Since);
        if Live then FClients.Cells[3, i + 1] := 'yes' else FClients.Cells[3, i + 1] := 'no';
        FClients.Cells[4, i + 1] := IPCMaskText(Mask, n);
        FClients.Cells[5, i + 1] := IntToStr(SamplesSent);
        FClients.Cells[6, i + 1] := FormatBytes(BytesSent);
        FClients.Cells[7, i + 1] := LastCmd;
        if Id = SelId then SelRow := i + 1;
      end;
    if SelRow > 0 then FClients.Row := SelRow;
    FBtnKick.Enabled := Length(Infos) > 0;
    FBtnKickAll.Enabled := Length(Infos) > 0;

    // log
    Log := TStringList.Create;
    try
      if FServer.TakeLog(Log) then
      begin
        FMemoLog.Lines.BeginUpdate;
        try
          FMemoLog.Lines.AddStrings(Log);
          while FMemoLog.Lines.Count > IPCMaxLog do
            FMemoLog.Lines.Delete(0);
        finally
          FMemoLog.Lines.EndUpdate;
        end;
        FMemoLog.SelStart := Length(FMemoLog.Text);
      end;
    finally
      Log.Free;
    end;
  finally
    FUpdating := False;
  end;
end;

end.
