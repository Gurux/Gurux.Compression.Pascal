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
/// Negotiated V.44 options shared by both peers. Each codec owns a validated copy.
unit Gurux.Compression.Options;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses SysUtils, Gurux.Compression.Types;

type
  /// Mutable settings. Configure before constructing codecs; not synchronized.
  TGXV44Options = class
  private
    FDefaultCodewordSize: Integer;
    FDefaultOrdinalSize: Integer;
    FMaxCodewords: Word;
    FMaximumStringLength: Integer;
    FHistoryLimit: Integer;
    FMaxDictionarySize: Cardinal;
    FEmitReinitControl: Boolean;
    FHex: Boolean;
    procedure SetDefaultCodewordSize(Value: Integer);
    procedure SetDefaultOrdinalSize(Value: Integer);
  public
    /// Creates defaults: 6/7-bit widths, 1024 codewords, 255-byte strings, 3072-byte history.
    constructor Create;
    /// Checks widths, codewords >= 256, history >= 512 and string limits 46/78/142/255.
    /// Raises EArgumentException on invalid settings; performs no allocation.
    procedure Validate;
    /// Returns a validated independent copy. Caller must Free the result.
    function Clone: TGXV44Options;
    /// Initial codeword width, 6..16. Setter rejects out-of-range values.
    property DefaultCodewordSize: Integer read FDefaultCodewordSize write SetDefaultCodewordSize;
    /// Initial ordinal width, 7..8. Setter rejects out-of-range values.
    property DefaultOrdinalSize: Integer read FDefaultOrdinalSize write SetDefaultOrdinalSize;
    /// Exclusive codeword bound, including reserved codes 0..3; 256..65535.
    property MaxCodewords: Word read FMaxCodewords write FMaxCodewords;
    /// Maximum complete dictionary string length: 46, 78, 142 or 255 bytes.
    property MaximumStringLength: Integer read FMaximumStringLength write FMaximumStringLength;
    /// Maximum decoded history between REINITs; at least 512 bytes.
    property HistoryLimit: Integer read FHistoryLimit write FHistoryLimit;
    /// Legacy .NET compatibility setting; unused. Use MaxCodewords.
    property MaxDictionarySize: Cardinal read FMaxDictionarySize write FMaxDictionarySize;
    /// Legacy .NET compatibility setting; unused. Required REINITs are always emitted.
    property EmitReinitControl: Boolean read FEmitReinitControl write FEmitReinitControl;
    /// Use hex diagnostic values even for printable bytes; does not affect the wire.
    property Hex: Boolean read FHex write FHex;
  end;

implementation

constructor TGXV44Options.Create;
begin
  inherited Create;
  FDefaultCodewordSize := 6;
  FDefaultOrdinalSize := 7;
  FMaxCodewords := 1024;
  FMaximumStringLength := 255;
  FHistoryLimit := 3072;
  FMaxDictionarySize := 3072;
end;

procedure TGXV44Options.SetDefaultCodewordSize(Value: Integer);
begin
  if (Value < 6) or (Value > 16) then
  begin
    raise EArgumentException.Create(SGXV44Options);
  end;
  FDefaultCodewordSize := Value;
end;

procedure TGXV44Options.SetDefaultOrdinalSize(Value: Integer);
begin
  if (Value < 7) or (Value > 8) then
  begin
    raise EArgumentException.Create(SGXV44Options);
  end;
  FDefaultOrdinalSize := Value;
end;

procedure TGXV44Options.Validate;
begin
  if (FDefaultCodewordSize < 6) or (FDefaultCodewordSize > 16) or
    (FDefaultOrdinalSize < 7) or (FDefaultOrdinalSize > 8) or
    (FMaxCodewords < 256) or (FHistoryLimit < 512) or
    not ((FMaximumStringLength = 46) or (FMaximumStringLength = 78) or
    (FMaximumStringLength = 142) or (FMaximumStringLength = 255)) then
  begin
    raise EArgumentException.Create(SGXV44Options);
  end;
end;

function TGXV44Options.Clone: TGXV44Options;
begin
  Validate;
  Result := TGXV44Options.Create;
  Result.FDefaultCodewordSize := FDefaultCodewordSize;
  Result.FDefaultOrdinalSize := FDefaultOrdinalSize;
  Result.FMaxCodewords := FMaxCodewords;
  Result.FMaximumStringLength := FMaximumStringLength;
  Result.FHistoryLimit := FHistoryLimit;
  Result.FMaxDictionarySize := FMaxDictionarySize;
  Result.FEmitReinitControl := FEmitReinitControl;
  Result.FHex := FHex;
end;

end.
