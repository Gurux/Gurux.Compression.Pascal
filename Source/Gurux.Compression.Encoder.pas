{ --------------------------------------------------------------------------
  Gurux Ltd

  Copyright (c) Gurux Ltd.

  This file is part of Gurux Device Framework.

  Commit: $Format:%H$
  Date:   $Format:%cI$

  This software is available under either of the following licenses:

  1. GNU General Public License, version 2 only (GPL-2.0-only).
     See the LICENSE file included with this distribution.

  2. A commercial license granted by Gurux Ltd under a separate written
     agreement. Use under this option requires a valid commercial license
     and is governed by the terms of that agreement.

  If you have not obtained a commercial license from Gurux Ltd,
  use of this software is governed by GPL-2.0-only.

  Commercial licensing: https://www.gurux.fi/

  SPDX-License-Identifier: GPL-2.0-only OR LicenseRef-Gurux-Commercial
  -------------------------------------------------------------------------- }
/// V.44 compression with bounded stream blocks and caller-owned output streams.
unit Gurux.Compression.Encoder;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses SysUtils, Classes, Gurux.Compression.Types, Gurux.Compression.Options,
  Gurux.Compression.Bits;

type
  /// Synchronous V.44 encoder. Instances are not thread safe or reentrant.
  /// Use one instance per concurrent operation; callbacks run on the calling thread.
  TGXV44Encoder = class
  private
    FOptions: TGXV44Options;
    FNodes: TGXV44Nodes;
    FDiagnosticStarts: array of Integer;
    FDiagnosticLengths: array of Integer;
    FRoot: array[0..255] of Word;
    FCount: Integer;
    FData: TBytes;
    FDataLength: Integer;
    FHasDiagnostics: Boolean;
    FWriter: TGXV44BitWriter;
    FHistory: Integer;
    FInputEnd: Integer;
    FOrdinalSize: Byte;
    FCodewordSize: Byte;
    FHex: Boolean;
    FBusy: Boolean;
    FOnTrace: TGXV44TraceEvent;
    procedure ResetDictionaries;
    procedure Notify(Operation: TGXV44Operation; const Value: string; Index: Int64);
    procedure WriteOrdinal(Value: Byte; Previous: TGXV44Operation);
    procedure WriteString(Codeword: Word; Extension: Integer);
    procedure LinkSibling(Head, NewCodeword: Word);
    procedure LinkChild(ParentIndex: Integer; NewCodeword: Word);
    procedure AddNode(Position, Count, DiagnosticStart, DiagnosticLength: Integer;
      Operation: TGXV44Operation);
    function SegmentMatches(Index, InputStart: Integer): Boolean;
    function FindLongestMatch(Codeword: Word; InputStart: Integer;
      out StringLength: Integer): Integer;
    procedure CompressBlock(const Input: TBytes; Count: Integer; Flush: Boolean);
    function GetNodeTree: TGXV44Nodes;
  public
    /// Creates a default encoder. Caller owns this object and must Free it.
    constructor Create; overload;
    /// Copies validated Options; caller retains ownership. Nil raises EArgumentException.
    constructor Create(Options: TGXV44Options); overload;
    /// Releases owned options, dictionary and diagnostic storage; never closes streams.
    destructor Destroy; override;
    /// Compresses arbitrary bytes. Nil and empty arrays produce a FLUSH-only stream.
    /// Returns caller-owned bytes; input is not modified or retained by reference.
    function Compress(const Input: TBytes): TBytes; overload;
    /// Encodes Unicode text as ASCII, replacing each non-ASCII UTF-16 code unit
    /// with '?', matching .NET. UnicodeString avoids FPC native code-page differences.
    /// For UTF-8 or other encodings, pass explicitly encoded bytes instead.
    function Compress(const Input: UnicodeString): TBytes; overload;
    /// Processes nonseekable/partial-read input in blocks <= min(HistoryLimit, 65536).
    /// Leaves both streams open. Nil/identical streams raise EArgumentException.
    /// I/O exceptions propagate; partial output may remain. Blocks in stream I/O.
    procedure Compress(Input, Output: TStream); overload;
    /// Clears dictionary, widths and retained diagnostics; rejects calls while processing.
    procedure Reset;
    /// Releases diagnostic bytes without changing dictionary metadata; call after processing.
    /// Previously returned snapshots remain valid. Reentrant calls raise EInvalidOperation.
    procedure ClearDiagnostics;
    /// Returns detached root-byte/first-segment pairs, in ascending root byte order.
    function GetRootArray: TGXV44Roots;
    /// Returns a detached dictionary copy; caller may retain or modify it.
    property NodeTree: TGXV44Nodes read GetNodeTree;
    /// Current ordinal width; restored to the configured default after REINIT.
    property OrdinalSize: Byte read FOrdinalSize;
    /// Current codeword width; restored to the configured default after REINIT.
    property CodewordSize: Byte read FCodewordSize;
    /// Diagnostic formatting only; does not change compressed data.
    property Hex: Boolean read FHex write FHex;
    /// Optional synchronous trace; nil avoids diagnostic snapshots and bit text.
    property OnTrace: TGXV44TraceEvent read FOnTrace write FOnTrace;
  end;

implementation

constructor TGXV44Encoder.Create;
var
  Options: TGXV44Options;
begin
  inherited Create;
  Options := TGXV44Options.Create;
  try
    Create(Options);
  finally
    Options.Free;
  end;
end;

constructor TGXV44Encoder.Create(Options: TGXV44Options);
begin
  inherited Create;
  if Options = nil then
  begin
    raise EArgumentException.Create(SGXV44Options);
  end;
  FOptions := Options.Clone;
  FHex := FOptions.Hex;
  SetLength(FNodes, FOptions.MaxCodewords - 4);
  SetLength(FDiagnosticStarts, Length(FNodes));
  SetLength(FDiagnosticLengths, Length(FNodes));
  ResetDictionaries;
end;

destructor TGXV44Encoder.Destroy;
begin
  FOptions.Free;
  inherited Destroy;
end;

procedure TGXV44Encoder.ResetDictionaries;
begin
  FillChar(FRoot, SizeOf(FRoot), 0);
  FCount := 0;
  FOrdinalSize := FOptions.DefaultOrdinalSize;
  FCodewordSize := FOptions.DefaultCodewordSize;
end;

procedure TGXV44Encoder.Reset;
begin
  if FBusy then
  begin
    raise EInvalidOperation.Create(SGXV44Busy);
  end;
  ResetDictionaries;
  ClearDiagnostics;
end;

procedure TGXV44Encoder.ClearDiagnostics;
begin
  if FBusy then
  begin
    raise EInvalidOperation.Create(SGXV44Busy);
  end;
  FData := nil;
  FDataLength := 0;
  FHasDiagnostics := False;
end;

function TGXV44Encoder.GetNodeTree: TGXV44Nodes;
var
  I: Integer;
begin
  Result := Copy(FNodes, 0, FCount);
  if FHasDiagnostics then
  begin
    for I := 0 to FCount - 1 do
    begin
      Result[I].Value := GXV44FormatBytes(FData, FDiagnosticStarts[I],
        FDiagnosticLengths[I], FHex);
    end;
  end;
end;

function TGXV44Encoder.GetRootArray: TGXV44Roots;
var
  I, Count: Integer;
begin
  Result := nil;
  Count := 0;
  for I := 0 to 255 do
  begin
    if FRoot[I] <> 0 then
    begin
      Inc(Count);
    end;
  end;
  SetLength(Result, Count);
  Count := 0;
  for I := 0 to 255 do
  begin
    if FRoot[I] <> 0 then
    begin
      Result[Count].Ordinal := I;
      Result[Count].Codeword := FRoot[I];
      Inc(Count);
    end;
  end;
end;

procedure TGXV44Encoder.Notify(Operation: TGXV44Operation;
  const Value: string; Index: Int64);
var
  Args: TGXV44TraceArgs;
  Handler: TGXV44TraceEvent;
begin
  Handler := FOnTrace;
  if not Assigned(Handler) then
  begin
    Exit;
  end;
  Args.Compress := True;
  Args.Operation := Operation;
  Args.Value := Value;
  Args.Index := Index;
  Args.Stop := False;
  Args.Uncompressed := Copy(FData, 0, FDataLength);
  Args.Compressed := FWriter.Trace;
  Args.NodeTree := GetNodeTree;
  Args.StringCollection := nil;
  Handler(Self, Args);
  if Args.Stop then
  begin
    raise EGXV44Cancelled.Create(SGXV44Cancelled);
  end;
end;

procedure TGXV44Encoder.WriteOrdinal(Value: Byte; Previous: TGXV44Operation);
begin
  if (Value > 127) and (FOrdinalSize = 7) then
  begin
    FWriter.Write(1, 1);
    FWriter.Write(2, FCodewordSize);
    Inc(FOrdinalSize);
  end
  else if Previous = voCodeword then
  begin
    FWriter.Write(0, 1);
  end;
  FWriter.Write(0, 1);
  FWriter.Write(Value, FOrdinalSize);
end;

procedure TGXV44Encoder.WriteString(Codeword: Word; Extension: Integer);
begin
  FWriter.Write(1, 1);
  while Cardinal(Codeword) >= (Cardinal(1) shl FCodewordSize) do
  begin
    FWriter.Write(2, FCodewordSize);
    Inc(FCodewordSize);
    FWriter.Write(1, 1);
  end;
  FWriter.Write(Codeword, FCodewordSize);
  if Extension > 0 then
  begin
    FWriter.Write(2, 2);
    GXV44WriteExtension(FWriter, Extension, FOptions.MaximumStringLength);
  end;
end;

procedure TGXV44Encoder.LinkSibling(Head, NewCodeword: Word);
var
  Index: Integer;
begin
  Index := Head - 4;
  while FNodes[Index].SideIndex <> 0 do
  begin
    Index := FNodes[Index].SideIndex - 4;
  end;
  FNodes[Index].SideIndex := NewCodeword;
end;

procedure TGXV44Encoder.LinkChild(ParentIndex: Integer; NewCodeword: Word);
begin
  if FNodes[ParentIndex].DownIndex = 0 then
  begin
    FNodes[ParentIndex].DownIndex := NewCodeword;
  end
  else
  begin
    LinkSibling(FNodes[ParentIndex].DownIndex, NewCodeword);
  end;
end;

procedure TGXV44Encoder.AddNode(Position, Count, DiagnosticStart,
  DiagnosticLength: Integer; Operation: TGXV44Operation);
begin
  FNodes[FCount].Codeword := Word(FCount + 4);
  FNodes[FCount].Position := Position;
  FNodes[FCount].Length := Count;
  FNodes[FCount].Operation := Operation;
  FNodes[FCount].DownIndex := 0;
  FNodes[FCount].SideIndex := 0;
  FNodes[FCount].Value := '';
  FDiagnosticStarts[FCount] := DiagnosticStart;
  FDiagnosticLengths[FCount] := DiagnosticLength;
  Inc(FCount);
end;

function TGXV44Encoder.SegmentMatches(Index, InputStart: Integer): Boolean;
var
  I, Start, Count: Integer;
begin
  Count := FNodes[Index].Length;
  Start := FNodes[Index].Position;
  Result := False;
  if (Count > FInputEnd - InputStart) or (Count > FHistory - Start) then
  begin
    Exit;
  end;
  for I := 0 to Count - 1 do
  begin
    if FData[InputStart + I] <> FData[Start + I] then
    begin
      Exit;
    end;
  end;
  Result := True;
end;

function TGXV44Encoder.FindLongestMatch(Codeword: Word; InputStart: Integer;
  out StringLength: Integer): Integer;
var
  Index, Matching, Tail: Integer;
begin
  Result := -1;
  StringLength := 0;
  Tail := 0;
  Index := Codeword - 4;
  while Index >= 0 do
  begin
    Matching := -1;
    while True do
    begin
      if (1 + Tail + FNodes[Index].Length <= FOptions.MaximumStringLength)
        and SegmentMatches(Index, InputStart) then
      begin
        Matching := Index;
        Break;
      end;
      if FNodes[Index].SideIndex = 0 then
      begin
        Break;
      end;
      Index := FNodes[Index].SideIndex - 4;
    end;
    if Matching < 0 then
    begin
      Break;
    end;
    Result := Matching;
    Inc(Tail, FNodes[Matching].Length);
    StringLength := Tail + 1;
    Inc(InputStart, FNodes[Matching].Length);
    Index := Integer(FNodes[Matching].DownIndex) - 4;
  end;
end;

procedure TGXV44Encoder.CompressBlock(const Input: TBytes; Count: Integer;
  Flush: Boolean);
var
  I, Index, Consumed, Extension, Source, Start, MaxExtension: Integer;
  RootChild, NewCodeword, MatchedCodeword: Word;
  Ch: Byte;
  Previous: TGXV44Operation;
begin
  FData := Copy(Input, 0, Count);
  FDataLength := Count;
  FHasDiagnostics := True;
  FWriter.ClearTrace;
  ResetDictionaries;
  FHistory := 0;
  FInputEnd := Count;
  if FInputEnd > FOptions.HistoryLimit then
  begin
    FInputEnd := FOptions.HistoryLimit;
  end;
  Notify(voStart, '', 0);
  Previous := voOrdinal;
  I := 0;
  while I < Count do
  begin
    if (I = FInputEnd) or (FCount + 4 >= FOptions.MaxCodewords) then
    begin
      FWriter.Write(1, 1);
      FWriter.Write(3, FCodewordSize);
      ResetDictionaries;
      FHistory := I;
      FInputEnd := Count - I;
      if FInputEnd > FOptions.HistoryLimit then
      begin
        FInputEnd := FOptions.HistoryLimit;
      end;
      Inc(FInputEnd, I);
      Notify(voReInit, '', I);
      Previous := voNone;
    end;
    Ch := FData[I];
    Inc(FHistory);
    RootChild := FRoot[Ch];
    Index := -1;
    Consumed := 0;
    if RootChild <> 0 then
    begin
      Index := FindLongestMatch(RootChild, I + 1, Consumed);
    end;
    if Index < 0 then
    begin
      WriteOrdinal(Ch, Previous);
      Previous := voOrdinal;
      NewCodeword := Word(FCount + 4);
      AddNode(I + 1, 1, I, 1, voOrdinal);
      if I + 1 < Count then
      begin
        if RootChild = 0 then
        begin
          FRoot[Ch] := NewCodeword;
        end
        else
        begin
          LinkSibling(RootChild, NewCodeword);
        end;
      end;
      Inc(I);
      Notify(voOrdinal, IntToStr(Ch), I);
      Continue;
    end;
    Inc(FHistory, Consumed - 1);
    Extension := 0;
    Start := I + Consumed;
    Source := FNodes[Index].Position + FNodes[Index].Length;
    MaxExtension := FOptions.MaximumStringLength - Consumed;
    while (Extension < MaxExtension) and (Start + Extension < FInputEnd)
      and (Source + Extension < FHistory) do
    begin
      if FData[Start + Extension] <> FData[Source + Extension] then
      begin
        Break;
      end;
      Inc(FHistory);
      Inc(Extension);
    end;
    NewCodeword := Word(FCount + 4);
    MatchedCodeword := FNodes[Index].Codeword;
    if Extension > 0 then
    begin
      LinkChild(Index, NewCodeword);
      AddNode(Start, Extension, I, Consumed + Extension, voStringExtension);
      WriteString(MatchedCodeword, Extension);
      Previous := voStringExtension;
      Inc(Consumed, Extension);
    end
    else
    begin
      WriteString(MatchedCodeword, 0);
      if Consumed < FOptions.MaximumStringLength then
      begin
        LinkChild(Index, NewCodeword);
        AddNode(Start, 1, I, Consumed, voCodeword);
      end;
      Previous := voCodeword;
    end;
    Inc(I, Consumed);
    Notify(Previous, IntToStr(MatchedCodeword), I);
  end;
  if Flush then
  begin
    FWriter.Write(1, 1);
    FWriter.Write(1, FCodewordSize);
  end;
  Notify(voEnd, '', Count);
end;

function TGXV44Encoder.Compress(const Input: TBytes): TBytes;
var
  Output: TMemoryStream;
begin
  Result := nil;
  if FBusy then
  begin
    raise EInvalidOperation.Create(SGXV44Busy);
  end;
  FBusy := True;
  try
    Output := TMemoryStream.Create;
    try
      FWriter := TGXV44BitWriter.Create(Output, Assigned(FOnTrace));
      try
        CompressBlock(Input, Length(Input), True);
        FWriter.Align;
        SetLength(Result, Output.Size);
        Output.Position := 0;
        if Length(Result) > 0 then
        begin
          Output.ReadBuffer(Result[0], Length(Result));
        end;
      finally
        FreeAndNil(FWriter);
      end;
    finally
      Output.Free;
    end;
  finally
    FBusy := False;
  end;
end;

function TGXV44Encoder.Compress(const Input: UnicodeString): TBytes;
var
  Bytes: TBytes;
  I: Integer;
begin
  SetLength(Bytes, Length(Input));
  for I := 1 to Length(Input) do
  begin
    if Ord(Input[I]) > 127 then
    begin
      Bytes[I - 1] := Ord('?');
    end
    else
    begin
      Bytes[I - 1] := Ord(Input[I]);
    end;
  end;
  Result := Compress(Bytes);
end;

procedure TGXV44Encoder.Compress(Input, Output: TStream);
var
  Block: TBytes;
  Count, ReadCount, Capacity: Integer;
  Pending: Byte;
  HasPending: Boolean;
begin
  if (Input = nil) or (Output = nil) or (Input = Output) then
  begin
    raise EArgumentException.Create(SGXV44Streams);
  end;
  if FBusy then
  begin
    raise EInvalidOperation.Create(SGXV44Busy);
  end;
  FBusy := True;
  try
    Capacity := FOptions.HistoryLimit;
    if Capacity > 65536 then
    begin
      Capacity := 65536;
    end;
    SetLength(Block, Capacity);
    FWriter := TGXV44BitWriter.Create(Output, Assigned(FOnTrace));
    try
      Pending := 0;
      HasPending := False;
      repeat
        Count := 0;
        if HasPending then
        begin
          Block[0] := Pending;
          Count := 1;
        end;
        while Count < Capacity do
        begin
          ReadCount := Input.Read(Block[Count], Capacity - Count);
          if ReadCount = 0 then
          begin
            Break;
          end;
          if (ReadCount < 0) or (ReadCount > Capacity - Count) then
          begin
            raise EStreamError.Create(SGXV44Streams);
          end;
          Inc(Count, ReadCount);
        end;
        HasPending := Input.Read(Pending, 1) = 1;
        CompressBlock(Block, Count, not HasPending);
        if HasPending then
        begin
          FWriter.Write(1, 1);
          FWriter.Write(3, FCodewordSize);
        end;
      until not HasPending;
      FWriter.Align;
    finally
      FreeAndNil(FWriter);
    end;
  finally
    FBusy := False;
  end;
end;

end.
