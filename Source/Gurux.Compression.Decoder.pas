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
/// Strict V.44 decompression with bounded history and negotiated dictionary limits.
unit Gurux.Compression.Decoder;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses SysUtils, Classes, Gurux.Compression.Types, Gurux.Compression.Options,
  Gurux.Compression.Bits;

type
  /// Synchronous V.44 decoder. Not thread safe or reentrant; callbacks run inline.
  /// Malformed tokens raise EGXV44InvalidData; prior completed blocks may be written.
  TGXV44Decoder = class
  private
    FOptions: TGXV44Options;
    FStrings: TGXV44DecoderEntries;
    FCount: Integer;
    FHistory: TBytes;
    FHistoryCount: Integer;
    FPreviousType: TGXV44Operation;
    FPreviousCodeword: Word;
    FPreviousOrdinal: Byte;
    FOrdinalSize: Byte;
    FCodewordSize: Byte;
    FDiagnosticStarts: array of Integer;
    FDiagnosticLengths: array of Integer;
    FLastValuePosition: Integer;
    FHasDiagnostics: Boolean;
    FBusy: Boolean;
    FOnTrace: TGXV44TraceEvent;
    FTraceBits: string;
    procedure ResetDictionaries;
    procedure AppendHistory(Value: Byte);
    procedure AddNewString(Count, LastPosition: Integer);
    function GetStringLength(Codeword: Word): Integer;
    procedure ProcessOrdinal(Value: Byte);
    procedure ProcessCodeword(Codeword: Integer);
    procedure ProcessExtension(Count: Integer);
    procedure CopyHistory(Start, Count: Integer);
    procedure Notify(Operation: TGXV44Operation; const Value: string; Index: Int64);
    function GetStringCollection: TGXV44DecoderEntries;
    procedure DecompressCore(Input, Output: TStream);
  public
    /// Creates a default decoder; caller must Free it.
    constructor Create; overload;
    /// Copies validated options, retaining no reference to the caller's object.
    /// Nil or invalid settings raise EArgumentException.
    constructor Create(Options: TGXV44Options); overload;
    /// Releases owned settings and storage; does not close caller streams.
    destructor Destroy; override;
    /// Decodes a complete byte stream. Empty/nil input is invalid (missing FLUSH).
    /// Returns caller-owned decoded bytes; input is not modified or retained.
    function Decompress(const Input: TBytes): TBytes; overload;
    /// Decodes LSB-first bit text. Spaces, CR, LF, '-', '{' and '}' are ignored.
    /// Other characters raise EArgumentException; incomplete bytes are zero padded.
    function Decompress(const Input: string): TBytes; overload;
    /// Reads nonseekable/partial-read streams without closing either one.
    /// Rejects nil/identical streams. I/O errors propagate; may block in stream I/O.
    /// A terminal FLUSH and zero alignment bits are mandatory.
    procedure Decompress(Input, Output: TStream); overload;
    /// Clears retained diagnostic values, preserving dictionary/history metadata.
    /// Existing snapshots remain valid. Reentrant calls raise EInvalidOperation.
    procedure ClearDiagnostics;
    /// Detached dictionary snapshot, independent of subsequent operations and cleanup.
    property StringCollection: TGXV44DecoderEntries read GetStringCollection;
    /// Current ordinal width in bits.
    property OrdinalSize: Byte read FOrdinalSize;
    /// Current codeword width in bits.
    property CodewordSize: Byte read FCodewordSize;
    /// Optional trace. Set Stop in a callback to raise EGXV44Cancelled.
    /// Streaming decode does not retain a complete compressed bit string.
    property OnTrace: TGXV44TraceEvent read FOnTrace write FOnTrace;
  end;

implementation

constructor TGXV44Decoder.Create;
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

constructor TGXV44Decoder.Create(Options: TGXV44Options);
begin
  inherited Create;
  if Options = nil then
  begin
    raise EArgumentException.Create(SGXV44Options);
  end;
  FOptions := Options.Clone;
  SetLength(FStrings, FOptions.MaxCodewords - 4);
  SetLength(FDiagnosticStarts, Length(FStrings));
  SetLength(FDiagnosticLengths, Length(FStrings));
  ResetDictionaries;
end;

destructor TGXV44Decoder.Destroy;
begin
  FOptions.Free;
  inherited Destroy;
end;

procedure TGXV44Decoder.ResetDictionaries;
begin
  FCount := 0;
  FHistoryCount := 0;
  FPreviousType := voNone;
  FPreviousCodeword := 0;
  FPreviousOrdinal := 0;
  FLastValuePosition := 0;
  FHasDiagnostics := True;
  FOrdinalSize := FOptions.DefaultOrdinalSize;
  FCodewordSize := FOptions.DefaultCodewordSize;
end;

procedure TGXV44Decoder.ClearDiagnostics;
begin
  if FBusy then
  begin
    raise EInvalidOperation.Create(SGXV44Busy);
  end;
  FHasDiagnostics := False;
end;

function TGXV44Decoder.GetStringCollection: TGXV44DecoderEntries;
var
  I: Integer;
begin
  Result := Copy(FStrings, 0, FCount);
  if FHasDiagnostics then
  begin
    for I := 0 to FCount - 1 do
    begin
      Result[I].Value := GXV44FormatBytes(FHistory, FDiagnosticStarts[I],
        FDiagnosticLengths[I], FOptions.Hex);
    end;
  end;
end;

procedure TGXV44Decoder.Notify(Operation: TGXV44Operation;
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
  Args.Compress := False;
  Args.Operation := Operation;
  Args.Value := Value;
  Args.Index := Index;
  Args.Stop := False;
  Args.Uncompressed := Copy(FHistory, 0, FHistoryCount);
  Args.Compressed := FTraceBits;
  Args.NodeTree := nil;
  Args.StringCollection := GetStringCollection;
  Handler(Self, Args);
  if Args.Stop then
  begin
    raise EGXV44Cancelled.Create(SGXV44Cancelled);
  end;
end;

procedure TGXV44Decoder.AppendHistory(Value: Byte);
var
  Capacity, Growth: Integer;
begin
  if FHistoryCount >= FOptions.HistoryLimit then
  begin
    raise EGXV44InvalidData.Create(SGXV44InvalidData);
  end;
  Capacity := Length(FHistory);
  if FHistoryCount = Capacity then
  begin
    Growth := Capacity;
    if Growth < 512 then
    begin
      Growth := 512;
    end;
    if Growth > FOptions.HistoryLimit - Capacity then
    begin
      Growth := FOptions.HistoryLimit - Capacity;
    end;
    SetLength(FHistory, Capacity + Growth);
  end;
  FHistory[FHistoryCount] := Value;
  Inc(FHistoryCount);
end;

procedure TGXV44Decoder.AddNewString(Count, LastPosition: Integer);
begin
  if (Count > FOptions.MaximumStringLength) or
    (FCount + 4 >= FOptions.MaxCodewords) then
  begin
    Exit;
  end;
  if (Count < 2) or (LastPosition < Count - 1) or
    (LastPosition >= FHistoryCount) then
  begin
    raise EGXV44InvalidData.Create(SGXV44InvalidData);
  end;
  FStrings[FCount].Codeword := Word(FCount + 4);
  FStrings[FCount].Position := LastPosition;
  FStrings[FCount].Length := Count;
  FStrings[FCount].StartPos := LastPosition - Count + 1;
  FStrings[FCount].Value := '';
  FDiagnosticStarts[FCount] := FLastValuePosition;
  FDiagnosticLengths[FCount] := FHistoryCount - FLastValuePosition;
  FLastValuePosition := FHistoryCount;
  Inc(FCount);
end;

function TGXV44Decoder.GetStringLength(Codeword: Word): Integer;
begin
  if (Codeword < 4) or (Codeword >= FCount + 4) then
  begin
    raise EGXV44InvalidData.Create(SGXV44InvalidData);
  end;
  Result := FStrings[Codeword - 4].Length;
end;

procedure TGXV44Decoder.ProcessOrdinal(Value: Byte);
begin
  AppendHistory(Value);
  case FPreviousType of
    voOrdinal: AddNewString(2, FHistoryCount - 1);
    voCodeword: AddNewString(GetStringLength(FPreviousCodeword) + 1,
      FHistoryCount - 1);
  end;
  FPreviousType := voOrdinal;
  FPreviousOrdinal := Value;
end;

procedure TGXV44Decoder.CopyHistory(Start, Count: Integer);
var
  I: Integer;
begin
  if (Start < 0) or (Count < 0) or (Count > FOptions.HistoryLimit - FHistoryCount) then
  begin
    raise EGXV44InvalidData.Create(SGXV44InvalidData);
  end;
  for I := 0 to Count - 1 do
  begin
    // Overlap is allowed: V.44 may reference bytes appended by this same token.
    if Start + I >= FHistoryCount then
    begin
      raise EGXV44InvalidData.Create(SGXV44InvalidData);
    end;
    AppendHistory(FHistory[Start + I]);
  end;
end;

procedure TGXV44Decoder.ProcessCodeword(Codeword: Integer);
var
  OutputStart, PreviousLength, Start, Count: Integer;
begin
  if (Codeword < 4) or (Codeword >= FOptions.MaxCodewords) or
    (Codeword > FCount + 4) then
  begin
    raise EGXV44InvalidData.Create(SGXV44InvalidData);
  end;
  PreviousLength := 0;
  if FPreviousType = voCodeword then
  begin
    PreviousLength := GetStringLength(FPreviousCodeword);
  end;
  OutputStart := FHistoryCount;
  if Codeword = FCount + 4 then
  begin
    case FPreviousType of
      voOrdinal:
        begin
          AppendHistory(FPreviousOrdinal);
          AppendHistory(FPreviousOrdinal);
        end;
      voCodeword:
        begin
          if PreviousLength >= FOptions.MaximumStringLength then
          begin
            raise EGXV44InvalidData.Create(SGXV44InvalidData);
          end;
          Start := FStrings[FPreviousCodeword - 4].StartPos;
          CopyHistory(Start, PreviousLength);
          AppendHistory(FHistory[Start]);
        end;
    else
      raise EGXV44InvalidData.Create(SGXV44InvalidData);
    end;
  end
  else
  begin
    Start := FStrings[Codeword - 4].StartPos;
    Count := FStrings[Codeword - 4].Length;
    CopyHistory(Start, Count);
  end;
  case FPreviousType of
    voOrdinal: AddNewString(2, OutputStart);
    voCodeword: AddNewString(PreviousLength + 1, OutputStart);
  end;
  FPreviousType := voCodeword;
  FPreviousCodeword := Word(Codeword);
end;

procedure TGXV44Decoder.ProcessExtension(Count: Integer);
var
  StringLength, Source: Integer;
begin
  if FPreviousType <> voCodeword then
  begin
    raise EGXV44InvalidData.Create(SGXV44InvalidData);
  end;
  StringLength := GetStringLength(FPreviousCodeword);
  if Count > FOptions.MaximumStringLength - StringLength then
  begin
    raise EGXV44InvalidData.Create(SGXV44InvalidData);
  end;
  Source := FStrings[FPreviousCodeword - 4].Position + 1;
  CopyHistory(Source, Count);
  AddNewString(StringLength + Count, FHistoryCount - 1);
  FPreviousType := voStringExtension;
end;

procedure TGXV44Decoder.DecompressCore(Input, Output: TStream);
var
  Reader: TGXV44BitReader;
  Prefix, Second, Code, Extension, Written, Next, MaxBits: Integer;
  AfterCodeword, EndedWithFlush: Boolean;
begin
  ResetDictionaries;
  Reader := TGXV44BitReader.Create(Input);
  try
    Notify(voStart, '', 0);
    AfterCodeword := False;
    EndedWithFlush := False;
    Written := 0;
    MaxBits := 0;
    Code := FOptions.MaxCodewords - 1;
    while Code > 0 do
    begin
      Inc(MaxBits);
      Code := Code shr 1;
    end;
    if MaxBits < FOptions.DefaultCodewordSize then
    begin
      MaxBits := FOptions.DefaultCodewordSize;
    end;
    try
      while Reader.TryPeek(Next) do
      begin
        EndedWithFlush := False;
        Prefix := Reader.Read(1);
        if AfterCodeword and (Prefix = 0) then
        begin
          Second := Reader.Read(1);
          if Second = 1 then
          begin
            Extension := GXV44ReadExtension(Reader, FOptions.MaximumStringLength);
            ProcessExtension(Extension);
            AfterCodeword := False;
            Notify(voStringExtension, IntToStr(Extension), Reader.Position);
            Continue;
          end;
        end;
        AfterCodeword := False;
        if Prefix = 0 then
        begin
          Code := Reader.Read(FOrdinalSize);
          ProcessOrdinal(Byte(Code));
          Notify(voOrdinal, IntToStr(Code), Reader.Position);
          Continue;
        end;
        Code := Reader.Read(FCodewordSize);
        case Code of
          0: raise EGXV44InvalidData.Create(SGXV44InvalidData);
          1:
            begin
              Reader.Align;
              if FHistoryCount > Written then
              begin
                Output.WriteBuffer(FHistory[Written], FHistoryCount - Written);
              end;
              Written := FHistoryCount;
              EndedWithFlush := True;
              Notify(voFlush, '', Reader.Position);
            end;
          2:
            begin
              if not Reader.TryPeek(Next) then
              begin
                raise EGXV44InvalidData.Create(SGXV44Truncated);
              end;
              if Next = 0 then
              begin
                if FOrdinalSize >= 8 then
                begin
                  raise EGXV44InvalidData.Create(SGXV44InvalidData);
                end;
                Inc(FOrdinalSize);
                Notify(voStepUpOrdinal, '', Reader.Position);
              end
              else
              begin
                if FCodewordSize >= MaxBits then
                begin
                  raise EGXV44InvalidData.Create(SGXV44InvalidData);
                end;
                Inc(FCodewordSize);
                Notify(voStepUpCodeword, '', Reader.Position);
              end;
            end;
          3:
            begin
              if FHistoryCount > Written then
              begin
                Output.WriteBuffer(FHistory[Written], FHistoryCount - Written);
              end;
              Written := 0;
              ResetDictionaries;
              Notify(voReInit, '', Reader.Position);
            end;
        else
          ProcessCodeword(Code);
          AfterCodeword := True;
          Notify(voCodeword, IntToStr(Code), Reader.Position);
        end;
      end;
      if not EndedWithFlush then
      begin
        raise EGXV44InvalidData.Create(SGXV44Truncated);
      end;
    except
      on E: EGXV44InvalidData do
      begin
        Notify(voError, E.Message, Reader.Position);
        raise;
      end;
    end;
    Notify(voEnd, '', Reader.Position);
  finally
    Reader.Free;
  end;
end;

function TGXV44Decoder.Decompress(const Input: TBytes): TBytes;
var
  Source, Output: TMemoryStream;
  I, Bit: Integer;
begin
  Result := nil;
  if FBusy then
  begin
    raise EInvalidOperation.Create(SGXV44Busy);
  end;
  FBusy := True;
  try
    FTraceBits := '';
    if Assigned(FOnTrace) then
    begin
      if Length(Input) > MaxInt div 8 then
      begin
        raise EArgumentException.Create(SGXV44Options);
      end;
      SetLength(FTraceBits, Length(Input) * 8);
      for I := 0 to Length(Input) - 1 do
      begin
        for Bit := 0 to 7 do
        begin
          FTraceBits[I * 8 + Bit + 1] := Char(Ord('0') + ((Input[I] shr Bit) and 1));
        end;
      end;
    end;
    Source := TMemoryStream.Create;
    try
      if Length(Input) > 0 then
      begin
        Source.WriteBuffer(Input[0], Length(Input));
      end;
      Source.Position := 0;
      Output := TMemoryStream.Create;
      try
        DecompressCore(Source, Output);
        SetLength(Result, Output.Size);
        Output.Position := 0;
        if Length(Result) > 0 then
        begin
          Output.ReadBuffer(Result[0], Length(Result));
        end;
      finally
        Output.Free;
      end;
    finally
      Source.Free;
    end;
  finally
    FTraceBits := '';
    FBusy := False;
  end;
end;

function TGXV44Decoder.Decompress(const Input: string): TBytes;
var
  Bytes: TBytes;
  I, Count, Offset: Integer;
begin
  Count := 0;
  for I := 1 to Length(Input) do
  begin
    case Input[I] of
      '0', '1': Inc(Count);
      ' ', #13, #10, '-', '{', '}': ;
    else
      raise EArgumentException.Create(SGXV44BitString);
    end;
  end;
  Offset := Count div 8;
  if Count mod 8 <> 0 then
  begin
    Inc(Offset);
  end;
  SetLength(Bytes, Offset);
  Count := 0;
  for I := 1 to Length(Input) do
  begin
    if (Input[I] = '0') or (Input[I] = '1') then
    begin
      if Input[I] = '1' then
      begin
        Offset := Count div 8;
        Bytes[Offset] := Bytes[Offset] or Byte(1 shl (Count mod 8));
      end;
      Inc(Count);
    end;
  end;
  Result := Decompress(Bytes);
end;

procedure TGXV44Decoder.Decompress(Input, Output: TStream);
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
    FTraceBits := '';
    DecompressCore(Input, Output);
  finally
    FTraceBits := '';
    FBusy := False;
  end;
end;

end.
