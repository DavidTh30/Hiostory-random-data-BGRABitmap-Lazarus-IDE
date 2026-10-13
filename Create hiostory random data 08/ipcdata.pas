unit IPCData;

{
  IPC for HistoryRandomData - TCP on 127.0.0.1 (or the network), text lines.

  Every data set is a "topic". Clients choose the topics they want; values
  of topics a client did not subscribe to (or that the server does not
  publish) are sent as empty fields, so every D line has the same columns.

  Protocol v2 (UTF-8 lines ending with LF):

  server -> client
    HELLO HistoryRandomData <version>     sent on connect
    INTERVAL <ms>                         sample interval
    HEADER Time;Name [Type];...           data sets (same as the CSV header)
    TOPICS <n>                            n TOPIC lines follow
    TOPIC <i>;<name>;<type>;<published>   i = 1..n, published = 1 / 0
    HISTORY <n>                           a history block of n samples follows
    D <time>;<v1>;<v2>;...                one sample, time = TDateTime as number,
                                          Boolean as TRUE/FALSE, empty = not sent
    END                                   end of the history block
    RESET                                 data was regenerated: ask for history again
    PONG
    ERR <text>

  client -> server
    HISTORY <seconds>                     last <seconds> of data (0 = all)
    SUBSCRIBE [i,j,...]                   live samples on; topics (default: all)
    UNSUBSCRIBE [i,j,...]                 topics off; no list = live samples off
    TOPICS                                send the topic list again
    PING
    QUIT

  Every connection has its own thread; data for a client is queued and
  written by that thread, so a slow client never blocks the generator.
  Requests that need the generator's data are answered in the main thread
  (TThread.Synchronize).
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ssockets, Sockets;

const
  IPCProtocolVersion = 2;
  IPCDefaultPort = 50555;
  IPCServerName = 'HistoryRandomData';
  IPCMaxTopics = 8;
  IPCMaxOutBuffer = 64 * 1024 * 1024;   // a client that falls this far behind is dropped
  IPCMaxLog = 500;

type
  TIPCTopicMask = array[0..IPCMaxTopics - 1] of Boolean;
  TIPCTimeArray = array of TDateTime;
  TIPCDoubleArray = array of Double;
  TIPCValueArrays = array[0..IPCMaxTopics - 1] of TIPCDoubleArray;

  TIPCHeaderFunc = function: string of object;
  TIPCHistoryFunc = function(Seconds: Integer): string of object;

  { snapshot of one connection, for display }
  TIPCClientInfo = record
    Id: Integer;
    Peer: string;
    Since: TDateTime;
    Live: Boolean;
    Mask: TIPCTopicMask;
    BytesSent, SamplesSent, LinesIn: Int64;
    LastCmd: string;
  end;
  TIPCClientInfos = array of TIPCClientInfo;

  TIPCDataServer = class;

  { One connected client }

  TIPCClientConn = class(TThread)
  private
    FServer: TIPCDataServer;
    FStream: TSocketStream;
    FLock: TCriticalSection;
    FOut: string;
    FInfo: TIPCClientInfo;
    FHistSeconds: Integer;
    FHistText: string;
    procedure DoGetHistory;
    procedure DoGetHeader;
    procedure HandleLine(const Line: string);
    function ParseTopicList(const Arg: string; out Mask: TIPCTopicMask): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TIPCDataServer; AStream: TSocketStream; AId: Integer);
    destructor Destroy; override;
    procedure QueueOut(const S: string; Samples: Integer = 0);
    function Info: TIPCClientInfo;
  end;

  { Accept loop }

  TIPCAcceptThread = class(TThread)
  private
    FServer: TIPCDataServer;
    FInet: TInetServer;
    procedure ServerIdle(Sender: TObject);
    procedure ServerConnect(Sender: TObject; Data: TSocketStream);
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TIPCDataServer);
  end;

  { TIPCDataServer }

  TIPCDataServer = class
  private
    FPort: Word;
    FAllInterfaces: Boolean;
    FIntervalMs: Integer;
    FAccept: TIPCAcceptThread;
    FClients: TList;
    FLock: TCriticalSection;
    FLastError: string;
    FStartedAt: TDateTime;
    FNextId: Integer;
    FBytesTotal: Int64;
    // topics
    FHeader: string;
    FTopicCount: Integer;
    FTopicNames, FTopicKinds: array[0..IPCMaxTopics - 1] of string;
    FTopicEnabled: TIPCTopicMask;
    FTopicSamples: array[0..IPCMaxTopics - 1] of Int64;
    FLog: TStringList;
    FOnGetHeader: TIPCHeaderFunc;
    FOnGetHistory: TIPCHistoryFunc;
    FOnChange: TNotifyEvent;
    procedure AddClient(C: TIPCClientConn);
    procedure RemoveClient(C: TIPCClientConn);
    procedure NotifyChange;
    procedure DoChange;
    function GetActive: Boolean;
    function EffectiveMask(const ClientMask: TIPCTopicMask): TIPCTopicMask;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    procedure Log(const S: string);
    { moves the activity log into Lines }
    function TakeLog(Lines: TStrings): Boolean;

    { topics = columns of the header "Time;Name [Type];..."; sends the new
      HEADER + TOPICS to every client }
    procedure SetHeader(const AHeader: string);
    function TopicsBlock: string;
    procedure SetTopicEnabled(Index: Integer; AEnabled: Boolean);
    function TopicEnabled(Index: Integer): Boolean;
    function TopicCount: Integer;
    function TopicName(Index: Integer): string;
    function TopicKind(Index: Integer): string;
    function TopicSamples(Index: Integer): Int64;
    function TopicSubscribers(Index: Integer): Integer;

    { live samples ("D ..." lines with all columns): every subscribed client
      gets them filtered to its topics }
    procedure Publish(const Lines: string);
    { messages for every client (RESET ...) }
    procedure BroadcastAll(const Lines: string);
    function ClientCount: Integer;
    function SubscriberCount: Integer;
    function ClientInfos: TIPCClientInfos;
    procedure KickClient(AId: Integer);
    procedure KickAll;
    function BytesTotal: Int64;

    property Active: Boolean read GetActive;
    property StartedAt: TDateTime read FStartedAt;
    property Port: Word read FPort write FPort;
    property AllInterfaces: Boolean read FAllInterfaces write FAllInterfaces;
    property IntervalMs: Integer read FIntervalMs write FIntervalMs;
    property LastError: string read FLastError;
    { called in the main thread }
    property OnGetHeader: TIPCHeaderFunc read FOnGetHeader write FOnGetHeader;
    property OnGetHistory: TIPCHistoryFunc read FOnGetHistory write FOnGetHistory;
    { called in the main thread when clients connect / disconnect / change }
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { Client side: one connection thread, raw lines }

  TIPCClientState = (csDisconnected, csConnecting, csConnected);

  TIPCDataClient = class(TThread)
  private
    FHost: string;
    FPort: Word;
    FLock: TCriticalSection;
    FOut: string;
    FIn: TStringList;          // received lines, picked up by the main thread
    FState: TIPCClientState;
    FError: string;
    FBytesIn, FBytesOut: Int64;
    procedure SetState(AState: TIPCClientState; const AError: string = '');
  protected
    procedure Execute; override;
  public
    constructor Create(const AHost: string; APort: Word);
    destructor Destroy; override;
    procedure Send(const Line: string);
    { moves all received lines into Lines; True when there were any }
    function TakeLines(Lines: TStrings): Boolean;
    function State: TIPCClientState;
    function ErrorText: string;
    function BytesIn: Int64;
    function BytesOut: Int64;
  end;

function IPCSampleTime(T: TDateTime): string;
{ keeps only the fields of D lines whose topic is in Mask }
function IPCFilterLines(const Lines: string; const Mask: TIPCTopicMask; TopicCount: Integer;
  out Samples: Integer): string;
function IPCMaskText(const Mask: TIPCTopicMask; TopicCount: Integer): string;

implementation

const
  {$ifdef windows}
  ErrTimedOut = 10060;       // WSAETIMEDOUT
  ErrWouldBlock = 10035;     // WSAEWOULDBLOCK
  {$else}
  ErrTimedOut = 110;         // ETIMEDOUT
  ErrWouldBlock = 11;        // EAGAIN / EWOULDBLOCK
  {$endif}
  IOTimeoutMs = 100;

var
  IPCFS: TFormatSettings;

function IPCSampleTime(T: TDateTime): string;
begin
  Result := FormatFloat('0.0000000000', T, IPCFS);
end;

function IPCMaskText(const Mask: TIPCTopicMask; TopicCount: Integer): string;
var
  i, n: Integer;
begin
  Result := '';
  n := 0;
  for i := 0 to TopicCount - 1 do
    if Mask[i] then
    begin
      if Result <> '' then Result := Result + ',';
      Result := Result + IntToStr(i + 1);
      Inc(n);
    end;
  if (n = TopicCount) and (n > 0) then Result := 'all'
  else if n = 0 then Result := 'none';
end;

{ "D t;v1;v2;v3" -> "D t;v1;;v3" for Mask = [1, 0, 1] }
function IPCFilterLines(const Lines: string; const Mask: TIPCTopicMask; TopicCount: Integer;
  out Samples: Integer): string;
var
  All: Boolean;
  i, P, LineEnd, FieldStart, FieldEnd, Col: Integer;
  Line, OutLine: string;
begin
  Samples := 0;
  All := True;
  for i := 0 to TopicCount - 1 do
    if not Mask[i] then All := False;
  P := 1;
  Result := '';
  if All then
  begin
    // nothing to remove - only count the samples (line starts "D ")
    for i := 1 to Length(Lines) - 1 do
      if (Lines[i] = 'D') and (Lines[i + 1] = ' ') and ((i = 1) or (Lines[i - 1] = #10)) then
        Inc(Samples);
    Exit(Lines);
  end;

  while P <= Length(Lines) do
  begin
    LineEnd := P;
    while (LineEnd <= Length(Lines)) and (Lines[LineEnd] <> #10) do Inc(LineEnd);
    Line := Copy(Lines, P, LineEnd - P);
    P := LineEnd + 1;
    if (Length(Line) > 2) and (Line[1] = 'D') and (Line[2] = ' ') then
    begin
      Inc(Samples);
      // time
      FieldEnd := 3;
      while (FieldEnd <= Length(Line)) and (Line[FieldEnd] <> ';') do Inc(FieldEnd);
      OutLine := Copy(Line, 1, FieldEnd - 1);
      Col := 0;
      while FieldEnd <= Length(Line) do
      begin
        FieldStart := FieldEnd + 1;
        FieldEnd := FieldStart;
        while (FieldEnd <= Length(Line)) and (Line[FieldEnd] <> ';') do Inc(FieldEnd);
        if (Col < IPCMaxTopics) and Mask[Col] then
          OutLine := OutLine + ';' + Copy(Line, FieldStart, FieldEnd - FieldStart)
        else
          OutLine := OutLine + ';';
        Inc(Col);
      end;
      Result := Result + OutLine + #10;
    end
    else
      Result := Result + Line + #10;
  end;
end;

function IsTimeout(Err: Integer): Boolean;
begin
  Result := (Err = ErrTimedOut) or (Err = ErrWouldBlock) or (Err = 0);
end;

{ Writes all of S; gives up after ~10 s without progress }
function WriteAll(AStream: TSocketStream; const S: string): Boolean;
var
  P, N, Stalls: Integer;
begin
  Result := True;
  P := 1;
  Stalls := 0;
  while P <= Length(S) do
  begin
    N := AStream.Write(S[P], Length(S) - P + 1);
    if N > 0 then
    begin
      Inc(P, N);
      Stalls := 0;
    end
    else if IsTimeout(AStream.LastError) and (Stalls < 100) then
      Inc(Stalls)
    else
      Exit(False);
  end;
end;

{ Splits complete lines off Buf (CR/LF tolerant) }
procedure ExtractLines(var Buf: string; Lines: TStrings);
var
  P, Start: Integer;
  L: string;
begin
  Start := 1;
  repeat
    P := Start;
    while (P <= Length(Buf)) and (Buf[P] <> #10) do Inc(P);
    if P > Length(Buf) then Break;
    L := Copy(Buf, Start, P - Start);
    Start := P + 1;
    if (L <> '') and (L[Length(L)] = #13) then SetLength(L, Length(L) - 1);
    if L <> '' then Lines.Add(L);
  until False;
  Delete(Buf, 1, Start - 1);
end;

{ TIPCClientConn }

constructor TIPCClientConn.Create(AServer: TIPCDataServer; AStream: TSocketStream; AId: Integer);
var
  A: TSockAddr;
  i: Integer;
begin
  FServer := AServer;
  FStream := AStream;
  FLock := TCriticalSection.Create;
  A := AStream.RemoteAddress;
  FInfo.Id := AId;
  FInfo.Peer := NetAddrToStr(A.sin_addr) + ':' + IntToStr(NToHs(A.sin_port));
  FInfo.Since := Now;
  for i := 0 to IPCMaxTopics - 1 do
    FInfo.Mask[i] := True;
  FreeOnTerminate := True;
  inherited Create(True);
end;

destructor TIPCClientConn.Destroy;
begin
  FStream.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TIPCClientConn.QueueOut(const S: string; Samples: Integer);
var
  Drop: Boolean;
begin
  FLock.Enter;
  try
    Drop := Length(FOut) >= IPCMaxOutBuffer;
    if not Drop then
    begin
      FOut := FOut + S;
      Inc(FInfo.SamplesSent, Samples);
    end;
  finally
    FLock.Leave;
  end;
  // lock order is always server -> client, so log after leaving our lock
  if Drop and not Terminated then
  begin
    Terminate;
    FServer.Log(FInfo.Peer + ' dropped (too far behind)');
  end;
end;

function TIPCClientConn.Info: TIPCClientInfo;
begin
  FLock.Enter;
  try
    Result := FInfo;
  finally
    FLock.Leave;
  end;
end;

procedure TIPCClientConn.DoGetHeader;
begin
  if Assigned(FServer.FOnGetHeader) then
    FHistText := FServer.FOnGetHeader()
  else
    FHistText := 'Time';
end;

procedure TIPCClientConn.DoGetHistory;
begin
  if Assigned(FServer.FOnGetHistory) then
    FHistText := FServer.FOnGetHistory(FHistSeconds)
  else
    FHistText := 'HISTORY 0'#10'END'#10;
end;

{ "1,3" -> topics 1 and 3 }
function TIPCClientConn.ParseTopicList(const Arg: string; out Mask: TIPCTopicMask): Boolean;
var
  Parts: TStringList;
  i, n: Integer;
begin
  for i := 0 to IPCMaxTopics - 1 do
    Mask[i] := False;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ',';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := StringReplace(Arg, ' ', '', [rfReplaceAll]);
    Result := False;
    for i := 0 to Parts.Count - 1 do
    begin
      n := StrToIntDef(Parts[i], 0);
      if (n >= 1) and (n <= IPCMaxTopics) then
      begin
        Mask[n - 1] := True;
        Result := True;
      end;
    end;
  finally
    Parts.Free;
  end;
end;

procedure TIPCClientConn.HandleLine(const Line: string);
var
  Cmd, Arg, Filtered: string;
  P, i, n: Integer;
  M: TIPCTopicMask;
  Any: Boolean;
begin
  P := Pos(' ', Line);
  if P > 0 then
  begin
    Cmd := UpperCase(Copy(Line, 1, P - 1));
    Arg := Trim(Copy(Line, P + 1, MaxInt));
  end
  else
  begin
    Cmd := UpperCase(Trim(Line));
    Arg := '';
  end;
  FLock.Enter;
  try
    Inc(FInfo.LinesIn);
    if Cmd <> 'PING' then FInfo.LastCmd := Trim(Line);
  finally
    FLock.Leave;
  end;
  if Cmd <> 'PING' then
    FServer.Log(FInfo.Peer + ' > ' + Trim(Line));

  if Cmd = 'HISTORY' then
  begin
    FHistSeconds := StrToIntDef(Arg, 0);
    Synchronize(@DoGetHistory);      // data belongs to the main thread
    Filtered := IPCFilterLines(FHistText, FServer.EffectiveMask(Info.Mask),
      FServer.TopicCount, n);
    FHistText := '';
    QueueOut(Filtered, n);
  end
  else if Cmd = 'SUBSCRIBE' then
  begin
    FLock.Enter;
    try
      if (Arg = '') or SameText(Arg, 'ALL') then
      begin
        for i := 0 to IPCMaxTopics - 1 do FInfo.Mask[i] := True;
      end
      else if ParseTopicList(Arg, M) then
        FInfo.Mask := M;
      FInfo.Live := True;
    finally
      FLock.Leave;
    end;
    FServer.NotifyChange;
  end
  else if Cmd = 'UNSUBSCRIBE' then
  begin
    n := FServer.TopicCount;          // before our lock (lock order server -> client)
    FLock.Enter;
    try
      if Arg = '' then
        FInfo.Live := False
      else if ParseTopicList(Arg, M) then
      begin
        Any := False;
        for i := 0 to IPCMaxTopics - 1 do
        begin
          if M[i] then FInfo.Mask[i] := False;
          if FInfo.Mask[i] and (i < n) then Any := True;
        end;
        if not Any then FInfo.Live := False;
      end;
    finally
      FLock.Leave;
    end;
    FServer.NotifyChange;
  end
  else if Cmd = 'TOPICS' then
    QueueOut(FServer.TopicsBlock)
  else if Cmd = 'PING' then
    QueueOut('PONG'#10)
  else if Cmd = 'QUIT' then
    Terminate
  else
    QueueOut('ERR unknown command ' + Cmd + #10);
end;

procedure TIPCClientConn.Execute;
var
  Buf: array[0..8191] of Char;
  InBuf, OutNow, S: string;
  N, i: Integer;
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    try
      FStream.IOTimeout := IOTimeoutMs;
      Synchronize(@DoGetHeader);
      QueueOut(Format('HELLO %s %d'#10'INTERVAL %d'#10'HEADER %s'#10,
        [IPCServerName, IPCProtocolVersion, FServer.FIntervalMs, FHistText]) +
        FServer.TopicsBlock);
      FHistText := '';
      InBuf := '';
      while not Terminated do
      begin
        // send what is queued
        FLock.Enter;
        try
          OutNow := FOut;
          FOut := '';
        finally
          FLock.Leave;
        end;
        if OutNow <> '' then
        begin
          if not WriteAll(FStream, OutNow) then Break;
          FLock.Enter;
          try
            Inc(FInfo.BytesSent, Length(OutNow));
          finally
            FLock.Leave;
          end;
          FServer.FLock.Enter;
          try
            Inc(FServer.FBytesTotal, Length(OutNow));
          finally
            FServer.FLock.Leave;
          end;
        end;

        // read commands (waits up to IOTimeoutMs)
        N := FStream.Read(Buf, SizeOf(Buf));
        if N > 0 then
        begin
          SetString(S, PChar(@Buf[0]), N);
          InBuf := InBuf + S;
          Lines.Clear;
          ExtractLines(InBuf, Lines);
          for i := 0 to Lines.Count - 1 do
            HandleLine(Lines[i]);
          if Length(InBuf) > 65536 then Break;   // garbage, no line ends
        end
        else if N = 0 then
          Break                                  // closed by the client
        else if not IsTimeout(FStream.LastError) then
          Break;
      end;
    except
      // connection lost
    end;
  finally
    Lines.Free;
    FServer.RemoveClient(Self);
  end;
end;

{ TIPCAcceptThread }

constructor TIPCAcceptThread.Create(AServer: TIPCDataServer);
begin
  FServer := AServer;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TIPCAcceptThread.ServerIdle(Sender: TObject);
begin
  if Terminated then
    FInet.StopAccepting(False);
end;

procedure TIPCAcceptThread.ServerConnect(Sender: TObject; Data: TSocketStream);
var
  C: TIPCClientConn;
begin
  if Terminated then
  begin
    Data.Free;
    Exit;
  end;
  FServer.FLock.Enter;
  try
    Inc(FServer.FNextId);
    C := TIPCClientConn.Create(FServer, Data, FServer.FNextId);
  finally
    FServer.FLock.Leave;
  end;
  FServer.AddClient(C);
  C.Start;
end;

procedure TIPCAcceptThread.Execute;
var
  Host: string;
begin
  if FServer.FAllInterfaces then Host := '0.0.0.0' else Host := '127.0.0.1';
  try
    FInet := TInetServer.Create(Host, FServer.FPort);
    try
      FInet.ReuseAddress := True;
      FInet.AcceptIdleTimeOut := 200;   // check Terminated 5x per second
      FInet.OnIdle := @ServerIdle;
      FInet.OnConnect := @ServerConnect;
      FServer.Log(Format('listening on %s:%d', [Host, FServer.FPort]));
      FInet.StartAccepting;
    finally
      FreeAndNil(FInet);
    end;
  except
    on E: Exception do
    begin
      FServer.FLastError := E.Message;
      FServer.Log('error: ' + E.Message);
      FServer.NotifyChange;
    end;
  end;
end;

{ TIPCDataServer }

constructor TIPCDataServer.Create;
var
  i: Integer;
begin
  inherited Create;
  FPort := IPCDefaultPort;
  FIntervalMs := 500;
  FClients := TList.Create;
  FLock := TCriticalSection.Create;
  FLog := TStringList.Create;
  for i := 0 to IPCMaxTopics - 1 do
    FTopicEnabled[i] := True;
end;

destructor TIPCDataServer.Destroy;
begin
  Stop;
  TThread.RemoveQueuedEvents(@DoChange);
  FClients.Free;
  FLog.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TIPCDataServer.Start;
begin
  if Active then Exit;
  FLastError := '';
  FStartedAt := Now;
  FAccept := TIPCAcceptThread.Create(Self);
  FAccept.Start;
end;

{ Stops accepting and closes every connection. Waits for the threads
  while still serving their Synchronize calls (no deadlock). }
procedure TIPCDataServer.Stop;
var
  T0: QWord;
  WasActive: Boolean;
begin
  WasActive := FAccept <> nil;
  if FAccept <> nil then
  begin
    FAccept.Terminate;
    while not FAccept.Finished do
      CheckSynchronize(10);
    FreeAndNil(FAccept);
  end;
  KickAll;
  T0 := GetTickCount64;
  while (ClientCount > 0) and (GetTickCount64 - T0 < 3000) do
    CheckSynchronize(10);
  if WasActive then Log('stopped');
  NotifyChange;
end;

function TIPCDataServer.GetActive: Boolean;
begin
  Result := (FAccept <> nil) and not FAccept.Finished;
end;

procedure TIPCDataServer.Log(const S: string);
begin
  FLock.Enter;
  try
    FLog.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
    while FLog.Count > IPCMaxLog do FLog.Delete(0);
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.TakeLog(Lines: TStrings): Boolean;
begin
  FLock.Enter;
  try
    Result := FLog.Count > 0;
    Lines.AddStrings(FLog);
    FLog.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TIPCDataServer.AddClient(C: TIPCClientConn);
begin
  FLock.Enter;
  try
    FClients.Add(C);
  finally
    FLock.Leave;
  end;
  Log(C.Info.Peer + ' connected');
  NotifyChange;
end;

procedure TIPCDataServer.RemoveClient(C: TIPCClientConn);
begin
  FLock.Enter;
  try
    FClients.Remove(C);
  finally
    FLock.Leave;
  end;
  Log(C.Info.Peer + ' disconnected');
  NotifyChange;
end;

procedure TIPCDataServer.NotifyChange;
begin
  TThread.Queue(nil, @DoChange);
end;

procedure TIPCDataServer.DoChange;
begin
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TIPCDataServer.EffectiveMask(const ClientMask: TIPCTopicMask): TIPCTopicMask;
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to IPCMaxTopics - 1 do
      Result[i] := ClientMask[i] and FTopicEnabled[i];
  finally
    FLock.Leave;
  end;
end;

procedure TIPCDataServer.SetHeader(const AHeader: string);
var
  Parts: TStringList;
  i, P: Integer;
  F: string;
begin
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := AHeader;
    FLock.Enter;
    try
      FHeader := AHeader;
      FTopicCount := 0;
      for i := 1 to Parts.Count - 1 do
      begin
        if FTopicCount >= IPCMaxTopics then Break;
        F := Trim(Parts[i]);
        P := LastDelimiter('[', F);
        if (P > 0) and (F[Length(F)] = ']') then
        begin
          FTopicNames[FTopicCount] := Trim(Copy(F, 1, P - 1));
          FTopicKinds[FTopicCount] := Copy(F, P + 1, Length(F) - P - 1);
        end
        else
        begin
          FTopicNames[FTopicCount] := F;
          FTopicKinds[FTopicCount] := 'Double';
        end;
        Inc(FTopicCount);
      end;
    finally
      FLock.Leave;
    end;
  finally
    Parts.Free;
  end;
  if Active then
    BroadcastAll('HEADER ' + AHeader + #10 + TopicsBlock);
  NotifyChange;
end;

function TIPCDataServer.TopicsBlock: string;
var
  i: Integer;
begin
  FLock.Enter;
  try
    Result := 'TOPICS ' + IntToStr(FTopicCount) + #10;
    for i := 0 to FTopicCount - 1 do
      Result := Result + Format('TOPIC %d;%s;%s;%d'#10,
        [i + 1, FTopicNames[i], FTopicKinds[i], Ord(FTopicEnabled[i])]);
  finally
    FLock.Leave;
  end;
end;

procedure TIPCDataServer.SetTopicEnabled(Index: Integer; AEnabled: Boolean);
begin
  if (Index < 0) or (Index >= IPCMaxTopics) then Exit;
  FLock.Enter;
  try
    if FTopicEnabled[Index] = AEnabled then Exit;
    FTopicEnabled[Index] := AEnabled;
  finally
    FLock.Leave;
  end;
  if AEnabled then Log(Format('topic %d published', [Index + 1]))
  else Log(Format('topic %d not published', [Index + 1]));
  BroadcastAll(TopicsBlock);
  NotifyChange;
end;

function TIPCDataServer.TopicEnabled(Index: Integer): Boolean;
begin
  FLock.Enter;
  try
    Result := (Index >= 0) and (Index < IPCMaxTopics) and FTopicEnabled[Index];
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.TopicCount: Integer;
begin
  FLock.Enter;
  try
    Result := FTopicCount;
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.TopicName(Index: Integer): string;
begin
  FLock.Enter;
  try
    Result := FTopicNames[Index];
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.TopicKind(Index: Integer): string;
begin
  FLock.Enter;
  try
    Result := FTopicKinds[Index];
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.TopicSamples(Index: Integer): Int64;
begin
  FLock.Enter;
  try
    Result := FTopicSamples[Index];
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.TopicSubscribers(Index: Integer): Integer;
var
  i: Integer;
  Inf: TIPCClientInfo;
begin
  Result := 0;
  FLock.Enter;
  try
    for i := 0 to FClients.Count - 1 do
    begin
      Inf := TIPCClientConn(FClients[i]).Info;
      if Inf.Live and Inf.Mask[Index] then Inc(Result);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TIPCDataServer.Publish(const Lines: string);
var
  i, t, n: Integer;
  C: TIPCClientConn;
  Inf: TIPCClientInfo;
  M: TIPCTopicMask;
begin
  if Lines = '' then Exit;
  FLock.Enter;
  try
    for i := 0 to FClients.Count - 1 do
    begin
      C := TIPCClientConn(FClients[i]);
      Inf := C.Info;
      if not Inf.Live then Continue;
      for t := 0 to IPCMaxTopics - 1 do
        M[t] := Inf.Mask[t] and FTopicEnabled[t];
      C.QueueOut(IPCFilterLines(Lines, M, FTopicCount, n), n);
      for t := 0 to FTopicCount - 1 do
        if M[t] then Inc(FTopicSamples[t], n);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TIPCDataServer.BroadcastAll(const Lines: string);
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to FClients.Count - 1 do
      TIPCClientConn(FClients[i]).QueueOut(Lines);
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.ClientCount: Integer;
begin
  FLock.Enter;
  try
    Result := FClients.Count;
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.SubscriberCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for i := 0 to FClients.Count - 1 do
      if TIPCClientConn(FClients[i]).Info.Live then Inc(Result);
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.ClientInfos: TIPCClientInfos;
var
  i: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    SetLength(Result, FClients.Count);
    for i := 0 to FClients.Count - 1 do
      Result[i] := TIPCClientConn(FClients[i]).Info;
  finally
    FLock.Leave;
  end;
end;

procedure TIPCDataServer.KickClient(AId: Integer);
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to FClients.Count - 1 do
      if TIPCClientConn(FClients[i]).Info.Id = AId then
      begin
        TIPCClientConn(FClients[i]).Terminate;
        Log(TIPCClientConn(FClients[i]).Info.Peer + ' disconnected by the server');
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TIPCDataServer.KickAll;
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := 0 to FClients.Count - 1 do
      TIPCClientConn(FClients[i]).Terminate;
  finally
    FLock.Leave;
  end;
end;

function TIPCDataServer.BytesTotal: Int64;
begin
  FLock.Enter;
  try
    Result := FBytesTotal;
  finally
    FLock.Leave;
  end;
end;

{ TIPCDataClient }

constructor TIPCDataClient.Create(const AHost: string; APort: Word);
begin
  FHost := AHost;
  FPort := APort;
  FLock := TCriticalSection.Create;
  FIn := TStringList.Create;
  FState := csConnecting;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TIPCDataClient.Destroy;
begin
  Terminate;
  WaitFor;
  FIn.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TIPCDataClient.SetState(AState: TIPCClientState; const AError: string);
begin
  FLock.Enter;
  try
    FState := AState;
    if AError <> '' then FError := AError;
  finally
    FLock.Leave;
  end;
end;

procedure TIPCDataClient.Send(const Line: string);
begin
  FLock.Enter;
  try
    FOut := FOut + Line + #10;
  finally
    FLock.Leave;
  end;
end;

function TIPCDataClient.TakeLines(Lines: TStrings): Boolean;
begin
  FLock.Enter;
  try
    Result := FIn.Count > 0;
    if Result then
    begin
      Lines.AddStrings(FIn);
      FIn.Clear;
    end;
  finally
    FLock.Leave;
  end;
end;

function TIPCDataClient.State: TIPCClientState;
begin
  FLock.Enter;
  try
    Result := FState;
  finally
    FLock.Leave;
  end;
end;

function TIPCDataClient.ErrorText: string;
begin
  FLock.Enter;
  try
    Result := FError;
  finally
    FLock.Leave;
  end;
end;

function TIPCDataClient.BytesIn: Int64;
begin
  FLock.Enter;
  try
    Result := FBytesIn;
  finally
    FLock.Leave;
  end;
end;

function TIPCDataClient.BytesOut: Int64;
begin
  FLock.Enter;
  try
    Result := FBytesOut;
  finally
    FLock.Leave;
  end;
end;

procedure TIPCDataClient.Execute;
var
  Sock: TInetSocket;
  Buf: array[0..65535] of Char;
  InBuf, OutNow, S: string;
  N: Integer;
  Lines: TStringList;
begin
  Sock := nil;
  Lines := TStringList.Create;
  try
    try
      Sock := TInetSocket.Create(FHost, FPort, 3000);   // 3 s connect timeout
      Sock.IOTimeout := IOTimeoutMs;
      SetState(csConnected);
      InBuf := '';
      while not Terminated do
      begin
        FLock.Enter;
        try
          OutNow := FOut;
          FOut := '';
        finally
          FLock.Leave;
        end;
        if OutNow <> '' then
        begin
          if not WriteAll(Sock, OutNow) then
            raise Exception.Create('send failed');
          FLock.Enter;
          try
            Inc(FBytesOut, Length(OutNow));
          finally
            FLock.Leave;
          end;
        end;

        N := Sock.Read(Buf, SizeOf(Buf));
        if N > 0 then
        begin
          SetString(S, PChar(@Buf[0]), N);
          InBuf := InBuf + S;
          Lines.Clear;
          ExtractLines(InBuf, Lines);
          FLock.Enter;
          try
            FIn.AddStrings(Lines);
            Inc(FBytesIn, N);
          finally
            FLock.Leave;
          end;
        end
        else if N = 0 then
          raise Exception.Create('connection closed by the server')
        else if not IsTimeout(Sock.LastError) then
          raise Exception.CreateFmt('socket error %d', [Sock.LastError]);
      end;
      // polite goodbye
      WriteAll(Sock, 'QUIT'#10);
      SetState(csDisconnected);
    except
      on E: Exception do
        SetState(csDisconnected, E.Message);
    end;
  finally
    Sock.Free;
    Lines.Free;
  end;
end;

initialization
  IPCFS := DefaultFormatSettings;
  IPCFS.DecimalSeparator := '.';
end.
