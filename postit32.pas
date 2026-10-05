program PostIt32;

{ Posts a text file as a message into an EleBBS JAM message area,
  as either local mail or echomail. }

{$mode objfpc}{$H+}

uses
  Windows, SysUtils, Classes, DateUtils;

const
  Version = '1.0';

  JamSig: array[0..3] of Char = ('J', 'A', 'M', #0);

  MSG_LOCAL     = $00000001;
  MSG_PRIVATE   = $00000004;
  MSG_TYPELOCAL = $00800000;
  MSG_TYPEECHO  = $01000000;

  SF_OADDRESS     = 0;
  SF_SENDERNAME   = 2;
  SF_RECEIVERNAME = 3;
  SF_MSGID        = 4;
  SF_SUBJECT      = 6;
  SF_PID          = 7;

  AREA_LOCALMAIL = 0;
  AREA_ECHOMAIL  = 2;
  AREA_IS_JAM    = $80;

  { Byte offsets into CONFIG.RA (RA 2.5x CONFIGrecord) }
  CFG_MSGBASEPATH = 995;
  CFG_ADDRESS     = 1178;

  { MESSAGES.ELE (EleMessageRecord) }
  ELE_RECSIZE   = 287;
  ELE_ATTRIBUTE = 133;
  ELE_SQUISH    = $04;

  { FidoNet packet limits; tossers truncate anything longer }
  MaxEchoName    = 35;
  MaxEchoSubject = 71;
  MaxOriginLine  = 79;

type
  EPostIt = class(Exception);

  TFlagType = array[1..4] of Byte;

  TNetAddress = packed record
    Zone, Net, Node, Point: Word;
  end;

  TPath60 = String[60];

  { One record of MESSAGES.RA }
  TMessageRecord = packed record
    AreaNum       : Word;
    Unused        : Word;
    Name          : String[40];
    Typ           : Byte;
    MsgKinds      : Byte;
    Attribute     : Byte;
    DaysKill      : Byte;
    RecvKill      : Byte;
    CountKill     : Word;
    ReadSecurity  : Word;
    ReadFlags     : TFlagType;
    ReadNotFlags  : TFlagType;
    WriteSecurity : Word;
    WriteFlags    : TFlagType;
    WriteNotFlags : TFlagType;
    SysopSecurity : Word;
    SysopFlags    : TFlagType;
    SysopNotFlags : TFlagType;
    OriginLine    : String[60];
    AkaAddress    : Byte;
    Age           : Byte;
    JamBase       : String[60];
    Group         : Word;
    AltGroup      : array[1..3] of Word;
    Attribute2    : Byte;
    NetmailArea   : Word;
    FreeSpace2    : array[1..7] of Byte;
  end;

  TJamBaseHeader = packed record
    Signature   : array[0..3] of Char;
    DateCreated : LongWord;
    ModCounter  : LongWord;
    ActiveMsgs  : LongWord;
    PasswordCRC : LongWord;
    BaseMsgNum  : LongWord;
    Reserved    : array[1..1000] of Byte;
  end;

  TJamMsgHeader = packed record
    Signature     : array[0..3] of Char;
    Revision      : Word;
    ReservedWord  : Word;
    SubfieldLen   : LongWord;
    TimesRead     : LongWord;
    MsgIdCRC      : LongWord;
    ReplyCRC      : LongWord;
    ReplyTo       : LongWord;
    Reply1st      : LongWord;
    ReplyNext     : LongWord;
    DateWritten   : LongWord;
    DateReceived  : LongWord;
    DateProcessed : LongWord;
    MessageNumber : LongWord;
    Attribute     : LongWord;
    Attribute2    : LongWord;
    TxtOffset     : LongWord;
    TxtLen        : LongWord;
    PasswordCRC   : LongWord;
    Cost          : LongWord;
  end;

  TJamIndex = packed record
    ToCRC     : LongWord;
    HdrOffset : LongWord;
  end;

var
  CrcTable: array[0..255] of LongWord;

  OptFile, OptBoard, OptSubject, OptFrom, OptTo, OptAddr, OptOrigin: string;
  OptLocal, OptEcho, OptPrivate: Boolean;
  RaDir: string;

procedure Fail(const Msg: string);
begin
  raise EPostIt.Create(Msg);
end;

procedure Usage;
begin
  WriteLn('PostIt32 ', Version, ' - post a text file to an EleBBS JAM message area');
  WriteLn;
  WriteLn('Usage: POSTIT32 /F:<file> /B:<board> /S:<subject> /FR:<from> [/TO:<to>]');
  WriteLn('                /L | /E [/A:<address>] [/O:<origin>] [/P]');
  WriteLn;
  WriteLn('  /F:<file>     Text file to post');
  WriteLn('  /B:<board>    Area number from %RA%\MESSAGES.RA');
  WriteLn('  /S:<subject>  Message subject');
  WriteLn('  /FR:<from>    Sender name');
  WriteLn('  /TO:<to>      Receiver name (default: All)');
  WriteLn('  /L            Post as local mail');
  WriteLn('  /E            Post as echomail (adds tear/origin lines, MSGID, and');
  WriteLn('                flags the message in ECHOMAIL.JAM for the tosser)');
  WriteLn('  /A:<address>  Override the origin address, e.g. 1:234/56');
  WriteLn('                (default: the area''s AKA from CONFIG.RA / AKAS.BBS)');
  WriteLn('  /O:<origin>   Origin line text (default: the area''s origin line)');
  WriteLn('  /P            Mark the message private');
  WriteLn;
  WriteLn('Put quotes around values containing spaces, e.g. "/S:Weekly News".');
  WriteLn('The RA environment variable must point to the EleBBS system directory.');
end;

procedure InitCrcTable;
var
  i, j: Integer;
  c: LongWord;
begin
  for i := 0 to 255 do
  begin
    c := i;
    for j := 1 to 8 do
      if (c and 1) <> 0 then
        c := (c shr 1) xor $EDB88320
      else
        c := c shr 1;
    CrcTable[i] := c;
  end;
end;

{ JAM uses CRC-32 without the final inversion }
function JamCrc(const S: AnsiString): LongWord;
var
  i: Integer;
begin
  Result := $FFFFFFFF;
  for i := 1 to Length(S) do
    Result := CrcTable[(Result xor Byte(S[i])) and $FF] xor (Result shr 8);
end;

function IsValidAddress(const A: string): Boolean;
var
  ColonPos, SlashPos: Integer;
begin
  ColonPos := Pos(':', A);
  SlashPos := Pos('/', A);
  Result := (ColonPos > 1) and (SlashPos > ColonPos + 1) and (SlashPos < Length(A));
end;

procedure ParseArgs;
var
  i, p: Integer;
  Arg, Key, Value: string;
begin
  OptTo := 'All';

  for i := 1 to ParamCount do
  begin
    Arg := ParamStr(i);
    if (Length(Arg) < 2) or not (Arg[1] in ['/', '-']) then
      Fail('Unknown parameter: ' + Arg);
    Delete(Arg, 1, 1);

    p := Pos(':', Arg);
    if p > 0 then
    begin
      Key := UpperCase(Copy(Arg, 1, p - 1));
      Value := Copy(Arg, p + 1, MaxInt);
    end
    else
    begin
      Key := UpperCase(Arg);
      Value := '';
    end;

    if Key = 'F' then OptFile := Value
    else if Key = 'B' then OptBoard := Value
    else if Key = 'S' then OptSubject := Value
    else if Key = 'FR' then OptFrom := Value
    else if Key = 'TO' then OptTo := Value
    else if Key = 'A' then OptAddr := Value
    else if Key = 'O' then OptOrigin := Value
    else if (Key = 'L') or (Key = 'LOCAL') then OptLocal := True
    else if (Key = 'E') or (Key = 'ECHO') then OptEcho := True
    else if (Key = 'P') or (Key = 'PRIVATE') then OptPrivate := True
    else if (Key = '?') or (Key = 'H') then
    begin
      Usage;
      Halt(0);
    end
    else
      Fail('Unknown parameter: /' + Arg);
  end;

  if OptFile = '' then Fail('No file given (/F:<file>)');
  if not FileExists(OptFile) then Fail('File not found: ' + OptFile);
  if OptBoard = '' then Fail('No board given (/B:<board>)');
  if OptSubject = '' then Fail('No subject given (/S:<subject>)');
  if OptFrom = '' then Fail('No sender given (/FR:<from>)');
  if Trim(OptTo) = '' then OptTo := 'All';
  if OptLocal = OptEcho then Fail('Specify exactly one of /L (local) or /E (echomail)');

  if (OptAddr <> '') and not IsValidAddress(OptAddr) then
    Fail('Invalid address: ' + OptAddr);

  if OptEcho then
  begin
    OptFrom := Copy(OptFrom, 1, MaxEchoName);
    OptTo := Copy(OptTo, 1, MaxEchoName);
    OptSubject := Copy(OptSubject, 1, MaxEchoSubject);
  end;
end;

procedure NeedRaDir;
begin
  if RaDir = '' then
    Fail('The RA environment variable is not set; point it at the EleBBS system directory');
end;

function ReadAt(const FileName: string; Offset: Int64; var Buf; Size: Integer): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  if not FileExists(FileName) then Exit;
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    if Offset + Size > F.Size then Exit;
    F.Position := Offset;
    F.ReadBuffer(Buf, Size);
    Result := True;
  finally
    F.Free;
  end;
end;

{ AKAs 0..9 live in CONFIG.RA, AKAs 10 and up in AKAS.BBS }
function GetAkaAddress(Aka: Byte): string;
var
  A: TNetAddress;
  Ok: Boolean;
begin
  FillChar(A, SizeOf(A), 0);
  if Aka <= 9 then
    Ok := ReadAt(RaDir + 'CONFIG.RA', CFG_ADDRESS + Aka * SizeOf(A), A, SizeOf(A))
  else
    Ok := ReadAt(RaDir + 'AKAS.BBS', (Aka - 10) * SizeOf(A), A, SizeOf(A));

  if (not Ok) or (A.Zone = 0) then
    Fail(Format('AKA %d is not set up in %sCONFIG.RA / AKAS.BBS; use /A:<address>',
      [Aka, RaDir]));

  Result := Format('%d:%d/%d', [A.Zone, A.Net, A.Node]);
  if A.Point <> 0 then
    Result := Result + '.' + IntToStr(A.Point);
end;

function GetMsgBasePath: string;
var
  S: TPath60;
begin
  Result := RaDir;
  if ReadAt(RaDir + 'CONFIG.RA', CFG_MSGBASEPATH, S, SizeOf(S)) then
  begin
    if Length(S) > 60 then SetLength(S, 60);
    if Trim(S) <> '' then
      Result := IncludeTrailingPathDelimiter(Trim(S));
  end;
end;

function IsSquishArea(AreaNum: Word; RecIndex: Integer): Boolean;
var
  F: TFileStream;
  Buf: array[0..ELE_RECSIZE - 1] of Byte;
  FileName: string;
  Index: Integer;
begin
  Result := False;
  FileName := RaDir + 'MESSAGES.ELE';
  if not FileExists(FileName) then Exit;

  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    Index := 0;
    while F.Position + ELE_RECSIZE <= F.Size do
    begin
      F.ReadBuffer(Buf, ELE_RECSIZE);
      Inc(Index);
      if (PLongInt(@Buf[0])^ = AreaNum) or
         ((PLongInt(@Buf[0])^ = 0) and (Index = RecIndex)) then
      begin
        Result := (Buf[ELE_ATTRIBUTE] and ELE_SQUISH) <> 0;
        Exit;
      end;
    end;
  finally
    F.Free;
  end;
end;

procedure ResolveBoard(out JamBase, AreaName, AreaOrigin: string; out Aka: Byte);
var
  F: TFileStream;
  Rec: TMessageRecord;
  FileName: string;
  AreaNo, Code, RecIndex: Integer;
  Found: Boolean;
begin
  AreaOrigin := '';

  Val(OptBoard, AreaNo, Code);
  if (Code <> 0) or (AreaNo < 1) or (AreaNo > 65535) then
    Fail('Board must be an area number: ' + OptBoard);

  NeedRaDir;
  FileName := RaDir + 'MESSAGES.RA';
  if not FileExists(FileName) then
    Fail('Cannot find ' + FileName);

  Found := False;
  RecIndex := 0;

  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    if F.Size mod SizeOf(Rec) <> 0 then
      WriteLn('Warning: ', FileName, ' is not a multiple of ', SizeOf(Rec),
        ' bytes; area records may be misread.');

    while (not Found) and (F.Position + SizeOf(Rec) <= F.Size) do
    begin
      F.ReadBuffer(Rec, SizeOf(Rec));
      Inc(RecIndex);
      Found := Rec.AreaNum = AreaNo;
    end;

    { Older files may not fill in AreaNum, so fall back to the record position }
    if (not Found) and (Int64(AreaNo) * SizeOf(Rec) <= F.Size) then
    begin
      F.Position := Int64(AreaNo - 1) * SizeOf(Rec);
      F.ReadBuffer(Rec, SizeOf(Rec));
      RecIndex := AreaNo;
      Found := Trim(Rec.Name) <> '';
    end;
  finally
    F.Free;
  end;

  if not Found then Fail('Board ' + OptBoard + ' not found in ' + FileName);

  AreaName := Trim(Rec.Name);
  AreaOrigin := Trim(Rec.OriginLine);
  Aka := Rec.AkaAddress;
  JamBase := Trim(Rec.JamBase);

  if IsSquishArea(Rec.AreaNum, RecIndex) then
    Fail('Area "' + AreaName + '" is a Squish area; only JAM areas are supported');
  if ((Rec.Attribute and AREA_IS_JAM) = 0) or (JamBase = '') then
    Fail('Area "' + AreaName + '" is not a JAM area; only JAM areas are supported');
  if (ExtractFileDrive(JamBase) = '') and (JamBase[1] <> '\') then
    JamBase := RaDir + JamBase;

  if OptEcho and (Rec.Typ = AREA_LOCALMAIL) then
    WriteLn('Warning: area "', AreaName, '" is set up as local mail; posting as echomail anyway.');
  if OptLocal and (Rec.Typ = AREA_ECHOMAIL) then
    WriteLn('Warning: area "', AreaName, '" is an echomail area; the message will not be exported.');
end;

function ReadFileBytes(const FileName: string): AnsiString;
var
  F: TFileStream;
begin
  Result := '';
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

function BuildBody(const AreaOrigin: string): AnsiString;
var
  Origin, OriginLine: string;
begin
  Result := ReadFileBytes(OptFile);

  while (Result <> '') and (Result[Length(Result)] = #26) do
    SetLength(Result, Length(Result) - 1);
  Result := StringReplace(Result, #13#10, #13, [rfReplaceAll]);
  Result := StringReplace(Result, #10, #13, [rfReplaceAll]);
  if (Result <> '') and (Result[Length(Result)] <> #13) then
    Result := Result + #13;

  if OptEcho then
  begin
    Origin := OptOrigin;
    if Origin = '' then Origin := AreaOrigin;
    if Origin = '' then Origin := 'PostIt32';

    OriginLine := ' * Origin: ' + Origin;
    if Length(OriginLine) + Length(OptAddr) + 3 > MaxOriginLine then
      OriginLine := Copy(OriginLine, 1, MaxOriginLine - Length(OptAddr) - 3);

    Result := Result + '--- PostIt32 ' + Version + #13 +
      OriginLine + ' (' + OptAddr + ')' + #13;
  end;
end;

procedure TouchFile(const FileName: string);
begin
  if not FileExists(FileName) then
    TFileStream.Create(FileName, fmCreate).Free;
end;

procedure CreateJamBase(const Base: string);
var
  F: TFileStream;
  BaseHdr: TJamBaseHeader;
begin
  if ExtractFileDir(Base) <> '' then
    ForceDirectories(ExtractFileDir(Base));

  FillChar(BaseHdr, SizeOf(BaseHdr), 0);
  Move(JamSig, BaseHdr.Signature, 4);
  BaseHdr.DateCreated := LongWord(DateTimeToUnix(Now));
  BaseHdr.PasswordCRC := $FFFFFFFF;
  BaseHdr.BaseMsgNum := 1;

  F := TFileStream.Create(Base + '.JHR', fmCreate);
  try
    F.WriteBuffer(BaseHdr, SizeOf(BaseHdr));
  finally
    F.Free;
  end;
end;

procedure AddSubfield(Buf: TMemoryStream; Id: Word; const Data: AnsiString);
var
  HiId: Word;
  Len: LongWord;
begin
  HiId := 0;
  Len := Length(Data);
  Buf.WriteBuffer(Id, SizeOf(Id));
  Buf.WriteBuffer(HiId, SizeOf(HiId));
  Buf.WriteBuffer(Len, SizeOf(Len));
  if Len > 0 then Buf.WriteBuffer(Data[1], Len);
end;

function MakeSerial: LongWord;
begin
  Result := LongWord((DateTimeToUnix(Now) shl 8) and $FFFFFFFF) or LongWord(Random(256));
end;

procedure LockJam(F: TFileStream);
var
  Tries: Integer;
begin
  for Tries := 1 to 50 do
  begin
    if LockFile(F.Handle, 0, 0, 1, 0) then Exit;
    Sleep(100);
  end;
  Fail('Message base is locked by another program');
end;

function PostToJam(const Base: string; const Body: AnsiString): LongWord;
var
  HdrF, TxtF, IdxF: TFileStream;
  Sub: TMemoryStream;
  BaseHdr: TJamBaseHeader;
  MsgHdr: TJamMsgHeader;
  Idx: TJamIndex;
  MsgId: AnsiString;
  Locked: Boolean;
begin
  if not FileExists(Base + '.JHR') then CreateJamBase(Base);
  TouchFile(Base + '.JDT');
  TouchFile(Base + '.JDX');
  TouchFile(Base + '.JLR');

  HdrF := nil;
  TxtF := nil;
  IdxF := nil;
  Locked := False;
  Sub := TMemoryStream.Create;
  try
    HdrF := TFileStream.Create(Base + '.JHR', fmOpenReadWrite or fmShareDenyNone);
    TxtF := TFileStream.Create(Base + '.JDT', fmOpenReadWrite or fmShareDenyNone);
    IdxF := TFileStream.Create(Base + '.JDX', fmOpenReadWrite or fmShareDenyNone);
    LockJam(HdrF);
    Locked := True;

    HdrF.ReadBuffer(BaseHdr, SizeOf(BaseHdr));
    if not CompareMem(@BaseHdr.Signature, @JamSig, 4) then
      Fail(Base + '.JHR is not a JAM message base');

    Result := BaseHdr.BaseMsgNum + LongWord(IdxF.Size div SizeOf(TJamIndex));

    MsgId := '';
    if OptEcho then
    begin
      MsgId := OptAddr + ' ' + LowerCase(IntToHex(MakeSerial, 8));
      AddSubfield(Sub, SF_OADDRESS, OptAddr);
      AddSubfield(Sub, SF_MSGID, MsgId);
    end;
    AddSubfield(Sub, SF_SENDERNAME, OptFrom);
    AddSubfield(Sub, SF_RECEIVERNAME, OptTo);
    AddSubfield(Sub, SF_SUBJECT, OptSubject);
    AddSubfield(Sub, SF_PID, 'PostIt32 ' + Version);

    FillChar(MsgHdr, SizeOf(MsgHdr), 0);
    Move(JamSig, MsgHdr.Signature, 4);
    MsgHdr.Revision := 1;
    MsgHdr.SubfieldLen := Sub.Size;
    if MsgId <> '' then
      MsgHdr.MsgIdCRC := JamCrc(LowerCase(MsgId))
    else
      MsgHdr.MsgIdCRC := $FFFFFFFF;
    MsgHdr.ReplyCRC := $FFFFFFFF;
    MsgHdr.DateWritten := LongWord(DateTimeToUnix(Now));
    MsgHdr.MessageNumber := Result;
    MsgHdr.PasswordCRC := $FFFFFFFF;

    MsgHdr.Attribute := MSG_LOCAL;
    if OptEcho then
      MsgHdr.Attribute := MsgHdr.Attribute or MSG_TYPEECHO
    else
      MsgHdr.Attribute := MsgHdr.Attribute or MSG_TYPELOCAL;
    if OptPrivate then
      MsgHdr.Attribute := MsgHdr.Attribute or MSG_PRIVATE;

    MsgHdr.TxtOffset := LongWord(TxtF.Seek(0, soEnd));
    MsgHdr.TxtLen := Length(Body);
    if Length(Body) > 0 then TxtF.WriteBuffer(Body[1], Length(Body));

    Idx.ToCRC := JamCrc(LowerCase(OptTo));
    Idx.HdrOffset := LongWord(HdrF.Seek(0, soEnd));
    HdrF.WriteBuffer(MsgHdr, SizeOf(MsgHdr));
    HdrF.WriteBuffer(Sub.Memory^, Sub.Size);

    IdxF.Seek(0, soEnd);
    IdxF.WriteBuffer(Idx, SizeOf(Idx));

    Inc(BaseHdr.ActiveMsgs);
    Inc(BaseHdr.ModCounter);
    HdrF.Seek(0, soBeginning);
    HdrF.WriteBuffer(BaseHdr, SizeOf(BaseHdr));
  finally
    if Locked then UnlockFile(HdrF.Handle, 0, 0, 1, 0);
    IdxF.Free;
    TxtF.Free;
    HdrF.Free;
    Sub.Free;
  end;
end;

procedure FlagEchomail(const Base: string; MsgNum: LongWord);
var
  T: TextFile;
  FileName: string;
begin
  FileName := GetMsgBasePath + 'ECHOMAIL.JAM';
  AssignFile(T, FileName);
  if FileExists(FileName) then
    Append(T)
  else
    Rewrite(T);
  try
    WriteLn(T, Base, ' ', MsgNum);
  finally
    CloseFile(T);
  end;
end;

var
  JamBase, AreaName, AreaOrigin: string;
  Aka: Byte;
  Body: AnsiString;
  MsgNum: LongWord;
  Kind: string;

begin
  if ParamCount = 0 then
  begin
    Usage;
    Halt(0);
  end;

  InitCrcTable;
  Randomize;

  try
    ParseArgs;

    RaDir := GetEnvironmentVariable('RA');
    if RaDir <> '' then RaDir := IncludeTrailingPathDelimiter(RaDir);

    ResolveBoard(JamBase, AreaName, AreaOrigin, Aka);
    if OptEcho and (OptAddr = '') then
      OptAddr := GetAkaAddress(Aka);
    Body := BuildBody(AreaOrigin);
    MsgNum := PostToJam(JamBase, Body);
    if OptEcho then FlagEchomail(JamBase, MsgNum);

    if OptEcho then Kind := 'echomail' else Kind := 'local mail';
    if OptEcho then Kind := Kind + ' from ' + OptAddr;
    WriteLn('Posted ', OptFile, ' to ', AreaName, ' as message #', MsgNum, ' (', Kind, ').');
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'PostIt32: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
