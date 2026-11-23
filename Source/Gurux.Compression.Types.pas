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
/// Shared V.44 diagnostic value types. Arrays returned by codecs are detached snapshots.
unit Gurux.Compression.Types;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses SysUtils;

type
  /// Raised when compressed input is malformed, truncated or exceeds negotiated limits.
  EGXV44InvalidData = class(Exception);
  /// Raised when a trace handler sets Stop. The codec may be reused afterwards.
  EGXV44Cancelled = class(Exception);
  /// Token/diagnostic identifiers; numeric values match the .NET Operation enumeration.
  TGXV44Operation = (voNone = -3, voStart = -2, voEnd = -1,
    voOrdinal = 0, voCodeword = 1, voStringExtension = 2,
    voStepUpOrdinal = 3, voStepUpCodeword = 4, voFlush = 5,
    voReInit = 6, voError = 7, voProcessing = 8);

  /// Dictionary segment coordinates and links; all positions are zero based.
  TGXV44Node = record
    /// Wire codeword, starting at four.
    Codeword: Word;
    /// Start of the segment tail in the current history window.
    Position: Integer;
    /// Segment tail length, excluding ancestors and the implicit root byte.
    Length: Integer;
    /// First child codeword, or zero.
    DownIndex: Word;
    /// Next sibling codeword, or zero.
    SideIndex: Word;
    /// Token that created this segment.
    Operation: TGXV44Operation;
    /// Optional formatted token data; empty after ClearDiagnostics.
    Value: string;
  end;
  /// Caller-owned snapshot array; modifying it does not modify the encoder.
  TGXV44Nodes = array of TGXV44Node;

  /// Decoder dictionary string referencing the current decoded history window.
  TGXV44DecoderEntry = record
    /// Wire codeword, starting at four.
    Codeword: Word;
    /// Inclusive final byte position in the history.
    Position: Integer;
    /// Complete dictionary string length in bytes.
    Length: Integer;
    /// First history position, equal to Position - Length + 1.
    StartPos: Integer;
    /// Optional formatted token data; empty after ClearDiagnostics.
    Value: string;
  end;
  /// Caller-owned decoder dictionary snapshot.
  TGXV44DecoderEntries = array of TGXV44DecoderEntry;

  /// Root byte and first dictionary segment link.
  TGXV44Root = record
    /// Implicit first byte of dictionary strings under this root.
    Ordinal: Byte;
    /// First segment codeword.
    Codeword: Word;
  end;
  /// Caller-owned encoder root link snapshot.
  TGXV44Roots = array of TGXV44Root;

  /// Detached event data. The receiver may retain the record and its managed fields.
  TGXV44TraceArgs = record
    /// True for compression; False for decompression.
    Compress: Boolean;
    /// Current token or lifecycle event.
    Operation: TGXV44Operation;
    /// Token or error formatted for diagnostics, not protocol serialization.
    Value: string;
    /// Current input block or decoded history, owned by the snapshot.
    Uncompressed: TBytes;
    /// LSB-first bit text, empty when unavailable for streaming decoding.
    Compressed: string;
    /// Zero-based input or compressed bit position as indicated by the event.
    Index: Int64;
    /// Detached encoder dictionary, empty for decoder events.
    NodeTree: TGXV44Nodes;
    /// Detached decoder dictionary, empty for encoder events.
    StringCollection: TGXV44DecoderEntries;
    /// Set True to abort synchronously by raising EGXV44Cancelled.
    Stop: Boolean;
  end;
  /// Synchronous event. Sender owns the codec; do not reenter it from this callback.
  TGXV44TraceEvent = procedure(Sender: TObject; var Args: TGXV44TraceArgs) of object;

/// Formats a validated byte slice as ASCII or spaced uppercase hex; does not retain Data.
function GXV44FormatBytes(const Data: TBytes; Offset, Count: Integer;
  Hex: Boolean): string;

resourcestring
  /// Invalid codec settings or unsupported negotiated limits.
  SGXV44Options = 'Invalid V.44 options.';
  /// Invalid or unsupported compressed token/history reference.
  SGXV44InvalidData = 'Invalid V.44 data or negotiated limit exceeded.';
  /// Input ended before a complete token or mandatory terminal FLUSH.
  SGXV44Truncated = 'The V.44 stream is truncated or has no terminal FLUSH.';
  /// FLUSH alignment contains nonzero bits.
  SGXV44Padding = 'V.44 FLUSH padding must be zero.';
  /// Trace-requested synchronous cancellation.
  SGXV44Cancelled = 'The V.44 operation was stopped by the trace handler.';
  /// Nil streams and identical input/output are not supported.
  SGXV44Streams = 'Separate, non-nil input and output streams are required.';
  /// A codec instance cannot process overlapping or reentrant operations.
  SGXV44Busy = 'The V.44 instance is already processing an operation.';
  /// Bit strings accept only binary digits and documented formatting characters.
  SGXV44BitString = 'Invalid character in the V.44 bit string.';

implementation

function GXV44FormatBytes(const Data: TBytes; Offset, Count: Integer;
  Hex: Boolean): string;
const
  Digits: string = '0123456789ABCDEF';
var
  I, P: Integer;
  B: Byte;
begin
  Result := '';
  if (Offset < 0) or (Count < 0) or (Offset > Length(Data)) or
    (Count > Length(Data) - Offset) then
  begin
    Exit;
  end;
  if Count = 0 then
  begin
    Exit;
  end;
  if not Hex then
  begin
    for I := Offset to Offset + Count - 1 do
    begin
      if (Data[I] < 32) or (Data[I] > 126) then
      begin
        Hex := True;
        Break;
      end;
    end;
  end;
  if Hex then
  begin
    SetLength(Result, Count * 3 - 1);
    P := 1;
    for I := Offset to Offset + Count - 1 do
    begin
      B := Data[I];
      Result[P] := Digits[(B shr 4) + 1];
      Result[P + 1] := Digits[(B and 15) + 1];
      if P + 2 <= Length(Result) then
      begin
        Result[P + 2] := ' ';
      end;
      Inc(P, 3);
    end;
  end
  else
  begin
    SetLength(Result, Count);
    for I := 0 to Count - 1 do
    begin
      Result[I + 1] := Char(Data[Offset + I]);
    end;
  end;
end;

end.
