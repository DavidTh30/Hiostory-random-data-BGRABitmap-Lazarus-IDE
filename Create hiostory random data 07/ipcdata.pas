unit IPCData;

{
  IPC for HistoryRandomData - TCP on 127.0.0.1 (or the network), text lines.

  Protocol (UTF-8 lines ending with LF):

  server -> client
    HELLO HistoryRandomData <version>     sent on connect
    INTERVAL <ms>                         sample interval, sent on connect
    HEADER Time;Name [Type];...           data sets (same as the CSV header)
    HISTORY <n>                           a history block of n samples follows
    D <time>;<v1>;<v2>;...                one sample, time = TDateTime as number,
                                          Boolean as TRUE/FALSE
    END                                   end of the history block
    RESET                                 data was regenerated: ask for history again
    PONG                                  answer to PING
    ERR <text>

  client -> server
    HISTORY <seconds>                     last <seconds> of data (0 = all)
    SUBSCRIBE / UNSUBSCRIBE               live samples on / off
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
  IPCProtocolVersion = 1;
  IPCDefaultPort = 50555;
  IPCServerName = 'HistoryRandomData';
  IPCMaxOutBuffer = 64 * 1024 * 1024;   // a client that falls this far behind is dropped

type
  TIPCHeaderFunc = function: string of object;
  TIPCHistoryFunc = function(Seconds: Integer): string of object;

  TIPCDataServer = class;

  { One connected client }

  TIPCClientConn = class(TThread)
  private
    FServer: TIPCDataServer;
    FStream: TSocketStream;
    FLock: TCriticalSection;
    FOut: string;
    FSubscribed: Boolean;
    FPeer: string;
    FHistSeconds: Integer;
    FHistText: string;
    procedure DoGetHistory;
    procedure DoGetHeader;
    procedure HandleLine(const Line: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TIPCDataServer; AStream: TSocketStream);
    destructor Destroy; override;
    procedure QueueOut(const S: string);
    property Subscribed: Boolean read FSubscribed;
    property Peer: string read FPeer;
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
    FOnGetHeader: TIPCHeaderFunc;
    FOnGetHistory: TIPCHistoryFunc;
    FOnChange: TNotifyEvent;
    procedure AddClient(C: TIPCClientConn);
    procedure RemoveClient(C: TIPCClientConn);
    procedure NotifyChange;
    procedure DoChange;
    function GetActive: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    { live samples: only clients that sent SUBSCRIBE }
    procedure Broadcast(const Lines: string);
    { messages for every client (HEADER, RESET) }
    procedure BroadcastAll(const Lines: string);
    function ClientCount: Integer;
    function SubscriberCount: Integer;
    property Active: Boolean read GetActive;
    property Port: Word read FPort write FPort;
    property AllInterfaces: Boolean read FAllInterfaces write FAllInterfaces;
    property IntervalMs: Integer read FIntervalMs write FIntervalMs;
    property LastError: string read FLastError;
    { called in the main thread }
    property OnGetHeader: TIPCHeaderFunc read FOnGetHeader write FOnGetHeader;
    property OnGetHistory: TIPCHistoryFunc read FOnGetHistory write FOnGetHistory;
    { called in the main thread when clients connect / disconnect / fail }
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { Client side }

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
    FBytesIn: Int64;
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
  end;

function IPCSampleTime(T: TDateTime): string;

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
  P: Integer;
  L: string;
begin
  repeat
    P := Pos(#10, Buf);
    if P = 0 then Break;
    L := Copy(Buf, 1, P - 1);
    Delete(Buf, 1, P);
    if (L <> '') and (L[Length(L)] = #13) then SetLength(L, Length(L) - 1);
    if L <> '' then Lines.Add(L);
  until False;
end;

{ TIPCClientConn }

constructor TIPCClientConn.Create(AServer: TIPCDataServer; AStream: TSocketStream);
var
  A: TSockAddr;
begin
  FServer := AServer;
  FStream := AStream;
  FLock := TCriticalSection.Create;
  A := AStream.RemoteAddress;
  FPeer := NetAddrToStr(A.sin_addr) + ':' + IntToStr(NToHs(A.sin_port));
  FreeOnTerminate := True;
  inherited Create(True);
end;

destructor TIPCClientConn.Destroy;
begin
  FStream.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TIPCClientConn.QueueOut(const S: string);
begin
  FLock.Enter;
  try
    if Length(FOut) < IPCMaxOutBuffer then
      FOut := FOut + S
    else
      Terminate;             // far behind -> drop the client
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

procedure TIPCClientConn.HandleLine(const Line: string);
var
  Cmd, Arg: string;
  P: Integer;
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

  if Cmd = 'HISTORY' then
  begin
    FHistSeconds := StrToIntDef(Arg, 0);
    Synchronize(@DoGetHistory);      // data belongs to the main thread
    QueueOut(FHistText);
    FHistText := '';
  end
  else if Cmd = 'SUBSCRIBE' then
  begin
    FSubscribed := True;
    FServer.NotifyChange;
  end
  else if Cmd = 'UNSUBSCRIBE' then
  begin
    FSubscribed := False;
    FServer.NotifyChange;
  end
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
        [IPCServerName, IPCProtocolVersion, FServer.FIntervalMs, FHistText]));
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
        if (OutNow <> '') and not WriteAll(FStream, OutNow) then
          Break;

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
  C := TIPCClientConn.Create(FServer, Data);
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
      FInet.StartAccepting;
    finally
      FreeAndNil(FInet);
    end;
  except
    on E: Exception do
    begin
      FServer.FLastError := E.Message;
      FServer.NotifyChange;
    end;
  end;
end;

{ TIPCDataServer }

constructor TIPCDataServer.Create;
begin
  inherited Create;
  FPort := IPCDefaultPort;
  FIntervalMs := 500;
  FClients := TList.Create;
  FLock := TCriticalSection.Create;
end;

destructor TIPCDataServer.Destroy;
begin
  Stop;
  TThread.RemoveQueuedEvents(@DoChange);
  FClients.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TIPCDataServer.Start;
begin
  if Active then Exit;
  FLastError := '';
  FAccept := TIPCAcceptThread.Create(Self);
  FAccept.Start;
end;

{ Stops accepting and closes every connection. Waits for the threads
  while still serving their Synchronize calls (no deadlock). }
procedure TIPCDataServer.Stop;
var
  i: Integer;
  T0: QWord;
begin
  if FAccept <> nil then
  begin
    FAccept.Terminate;
    while not FAccept.Finished do
    begin
      CheckSynchronize(10);
    end;
    FreeAndNil(FAccept);
  end;
  FLock.Enter;
  try
    for i := 0 to FClients.Count - 1 do
      TIPCClientConn(FClients[i]).Terminate;
  finally
    FLock.Leave;
  end;
  T0 := GetTickCount64;
  while (ClientCount > 0) and (GetTickCount64 - T0 < 3000) do
    CheckSynchronize(10);
  NotifyChange;
end;

function TIPCDataServer.GetActive: Boolean;
begin
  Result := (FAccept <> nil) and not FAccept.Finished;
end;

procedure TIPCDataServer.AddClient(C: TIPCClientConn);
begin
  FLock.Enter;
  try
    FClients.Add(C);
  finally
    FLock.Leave;
  end;
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

procedure TIPCDataServer.Broadcast(const Lines: string);
var
  i: Integer;
begin
  if Lines = '' then Exit;
  FLock.Enter;
  try
    for i := 0 to FClients.Count - 1 do
      if TIPCClientConn(FClients[i]).Subscribed then
        TIPCClientConn(FClients[i]).QueueOut(Lines);
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
      if TIPCClientConn(FClients[i]).Subscribed then Inc(Result);
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
        if (OutNow <> '') and not WriteAll(Sock, OutNow) then
          raise Exception.Create('send failed');

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
