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
/// Internal strict LSB-first stream bit I/O. No stream ownership is transferred.
unit Gurux.Compression.Bits;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses Classes, SysUtils, Gurux.Compression.Types;

type
  /// Internal synchronous bit reader; buffers at most 23 bits, never seeks.
  TGXV44BitReader = class
  private
    FStream: TStream;
    FBuffer: Cardinal;
    FAvailable: Integer;
    FPosition: Int64;
  public
    /// Borrows a non-nil readable stream, leaving it open on destruction.
    constructor Create(Stream: TStream);
    /// Peeks one bit, or returns False at clean EOF; may block in Stream.Read.
    function TryPeek(out Bit: Integer): Boolean;
    /// Consumes 1..16 bits; raises EGXV44InvalidData on truncated input.
    function Read(Count: Integer): Integer;
    /// Consumes zero padding through the next byte boundary; rejects nonzero padding.
    procedure Align;
    /// Number of consumed wire bits, excluding lookahead.
    property Position: Int64 read FPosition;
  end;

  /// Internal synchronous writer; writes full bytes immediately, padding only at Align.
  TGXV44BitWriter = class
  private
    FStream: TStream;
    FBuffer: Cardinal;
    FAvailable: Integer;
    FPosition: Int64;
    FTrace: string;
    FCapture: Boolean;
  public
    /// Borrows an output stream. Capture optionally retains block-local LSB-first text.
    constructor Create(Stream: TStream; Capture: Boolean);
    /// Writes the low Count bits (1..16); may raise stream write errors.
    procedure Write(Value, Count: Integer);
    /// Writes the final partial byte with zero padding. Does not close or flush the stream.
    procedure Align;
    /// Clears block-local trace text without changing wire position or buffered bits.
    procedure ClearTrace;
    /// Returns captured unpadded bits. Empty when capture is disabled.
    property Trace: string read FTrace;
    /// Total number of unpadded bits written.
    property Position: Int64 read FPosition;
  end;

/// Internal negotiated extension length width: 5, 6, 7 or 8 bits.
function GXV44ExtensionWidth(Maximum: Integer): Integer;
/// Internal strict extension decoding; enforces Maximum - 2 and advances Reader.
function GXV44ReadExtension(Reader: TGXV44BitReader; Maximum: Integer): Integer;
/// Internal extension encoding for lengths 1..Maximum - 2.
procedure GXV44WriteExtension(Writer: TGXV44BitWriter; Value, Maximum: Integer);

implementation

constructor TGXV44BitReader.Create(Stream: TStream);
begin
  inherited Create;
  if Stream = nil then
  begin
    raise EArgumentException.Create(SGXV44Streams);
  end;
  FStream := Stream;
end;

function TGXV44BitReader.TryPeek(out Bit: Integer): Boolean;
var
  B: Byte;
begin
  if FAvailable = 0 then
  begin
    if FStream.Read(B, 1) = 0 then
    begin
      Bit := 0;
      Result := False;
      Exit;
    end;
    FBuffer := B;
    FAvailable := 8;
  end;
  Bit := Integer(FBuffer and 1);
  Result := True;
end;

function TGXV44BitReader.Read(Count: Integer): Integer;
var
  B: Byte;
begin
  if (Count < 1) or (Count > 16) then
  begin
    raise EArgumentException.Create(SGXV44Options);
  end;
  while FAvailable < Count do
  begin
    if FStream.Read(B, 1) = 0 then
    begin
      raise EGXV44InvalidData.Create(SGXV44Truncated);
    end;
    FBuffer := FBuffer or (Cardinal(B) shl FAvailable);
    Inc(FAvailable, 8);
  end;
  Result := Integer(FBuffer and ((Cardinal(1) shl Count) - 1));
  FBuffer := FBuffer shr Count;
  Dec(FAvailable, Count);
  Inc(FPosition, Count);
end;

procedure TGXV44BitReader.Align;
var
  Padding: Integer;
begin
  Padding := Integer((8 - FPosition mod 8) mod 8);
  if Padding > 0 then
  begin
    if Read(Padding) <> 0 then
    begin
      raise EGXV44InvalidData.Create(SGXV44Padding);
    end;
  end;
end;

constructor TGXV44BitWriter.Create(Stream: TStream; Capture: Boolean);
begin
  inherited Create;
  if Stream = nil then
  begin
    raise EArgumentException.Create(SGXV44Streams);
  end;
  FStream := Stream;
  FCapture := Capture;
end;

procedure TGXV44BitWriter.Write(Value, Count: Integer);
var
  B: Byte;
  I, Start: Integer;
begin
  if (Count < 1) or (Count > 16) or (Value < 0) or
    (Cardinal(Value) >= (Cardinal(1) shl Count)) then
  begin
    raise EArgumentException.Create(SGXV44Options);
  end;
  if FCapture then
  begin
    Start := Length(FTrace);
    SetLength(FTrace, Start + Count);
    for I := 0 to Count - 1 do
    begin
      FTrace[Start + I + 1] := Char(Ord('0') + ((Value shr I) and 1));
    end;
  end;
  FBuffer := FBuffer or (Cardinal(Value) shl FAvailable);
  Inc(FAvailable, Count);
  Inc(FPosition, Count);
  while FAvailable >= 8 do
  begin
    B := Byte(FBuffer and 255);
    FStream.WriteBuffer(B, 1);
    FBuffer := FBuffer shr 8;
    Dec(FAvailable, 8);
  end;
end;

procedure TGXV44BitWriter.Align;
var
  B: Byte;
begin
  if FAvailable > 0 then
  begin
    B := Byte(FBuffer and 255);
    FStream.WriteBuffer(B, 1);
    FBuffer := 0;
    FAvailable := 0;
  end;
end;

procedure TGXV44BitWriter.ClearTrace;
begin
  FTrace := '';
end;

function GXV44ExtensionWidth(Maximum: Integer): Integer;
begin
  case Maximum of
    46: Result := 5;
    78: Result := 6;
    142: Result := 7;
    255: Result := 8;
  else
    raise EArgumentException.Create(SGXV44Options);
  end;
end;

function GXV44ReadExtension(Reader: TGXV44BitReader; Maximum: Integer): Integer;
begin
  if Reader.Read(1) = 1 then
  begin
    Result := 1;
    Exit;
  end;
  Result := Reader.Read(2);
  if Result <> 0 then
  begin
    Inc(Result);
    Exit;
  end;
  if Reader.Read(1) = 0 then
  begin
    Result := Reader.Read(3) + 5;
  end
  else
  begin
    Result := Reader.Read(GXV44ExtensionWidth(Maximum)) + 13;
  end;
  if Result > Maximum - 2 then
  begin
    raise EGXV44InvalidData.Create(SGXV44InvalidData);
  end;
end;

procedure GXV44WriteExtension(Writer: TGXV44BitWriter; Value, Maximum: Integer);
begin
  if (Value < 1) or (Value > Maximum - 2) then
  begin
    raise EArgumentException.Create(SGXV44Options);
  end;
  if Value = 1 then
  begin
    Writer.Write(1, 1);
  end
  else if Value <= 4 then
  begin
    Writer.Write(0, 1);
    Writer.Write(Value - 1, 2);
  end
  else if Value <= 12 then
  begin
    Writer.Write(0, 4);
    Writer.Write(Value - 5, 3);
  end
  else
  begin
    Writer.Write(0, 3);
    Writer.Write(1, 1);
    Writer.Write(Value - 13, GXV44ExtensionWidth(Maximum));
  end;
end;

end.
