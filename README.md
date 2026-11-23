# Gurux.Compression.Pascal

V.44 binary compression and decompression for Delphi and Free Pascal, based on
the sibling `Gurux.Compression.Net` implementation. The Pascal encoder produces
the same bytes as the .NET encoder with matching settings and overloads.

The core uses only `SysUtils` and `Classes`. Source targets Delphi XE or newer
and Free Pascal 3.2.2 in Delphi mode. There are no GUI, package-manager or native
codec dependencies. Delphi compilation must still be verified with a licensed
Delphi installation; see [validation results](docs/validation.md).

## Use

Add `Source` to the unit search path. Delphi users may also open the runtime
package [Gurux.Compression.Pascal.dpk](Gurux.Compression.Pascal.dpk).

```pascal
uses SysUtils, Gurux.Compression.Encoder, Gurux.Compression.Decoder;

var
  Encoder: TGXV44Encoder;
  Decoder: TGXV44Decoder;
  Original, Compressed, Restored: TBytes;
begin
  Original := TEncoding.UTF8.GetBytes('Hello, hello, hello!');
  Encoder := TGXV44Encoder.Create;
  try
    Decoder := TGXV44Decoder.Create;
    try
      Compressed := Encoder.Compress(Original);
      Restored := Decoder.Decompress(Compressed);
    finally
      Decoder.Free;
    end;
  finally
    Encoder.Free;
  end;
end;
```

`Encoder.Compress(InputStream, OutputStream)` and
`Decoder.Decompress(InputStream, OutputStream)` work with nonseekable streams
and partial reads. Both streams remain open and must be separate objects.
Processing is synchronous and may block in stream I/O; stream exceptions
propagate, and already written output remains on failure. A zero-byte read
means EOF, as with ordinary blocking `TStream` implementations. No input stream
size or position query is required.

Each instance supports one operation at a time. Reentrant operations and
cleanup from trace handlers raise `EInvalidOperation`. Use distinct instances
for concurrent work and do not mutate properties from another thread.

## Options and wire format

Pass a `TGXV44Options` from `Gurux.Compression.Options` to either constructor.
The constructor validates and copies it; the caller still owns and frees the
options. Both peers must use matching negotiated values:

| Property | Default | Supported values |
| --- | --- | --- |
| `DefaultCodewordSize` | 6 | 6..16 bits |
| `DefaultOrdinalSize` | 7 | 7..8 bits |
| `MaxCodewords` | 1024 | 256..65535, including reserved codes 0..3 |
| `MaximumStringLength` | 255 | 46, 78, 142, 255 bytes |
| `HistoryLimit` | 3072 | 512..MaxInt bytes |
| `Hex` | False | Diagnostic formatting only |

Legacy `MaxDictionarySize` and `EmitReinitControl` are retained as no-effect
settings, as in .NET. Required REINIT controls are always emitted.

Fields are packed least significant bit first, with reserved controls 0..3,
adaptive STEPUP widths, string extensions, REINIT and terminal FLUSH. FLUSH
padding must be zero. Transparent mode is unsupported. Empty input compresses
to the single byte `$03`; an empty compressed stream is invalid. Malformed or
truncated data raises `EGXV44InvalidData`.

Stream compression bounds each input block to `min(HistoryLimit, 65536)` and
emits REINIT between blocks. Byte-array compression uses history windows within
the supplied array, matching the corresponding .NET overload. These overloads
can produce different valid encodings when stream block boundaries differ.
The decoder accepts both. Stream decompression retains at most `HistoryLimit`
history bytes plus dictionary metadata. Array overloads additionally allocate
whole input/output buffers. Default dictionaries and diagnostics require more
than 8 KB RAM; MCU support has not been measured or claimed.

## Diagnostics and Pascal API mapping

| .NET | Pascal |
| --- | --- |
| `GXV44Encoder` | `TGXV44Encoder` in `Gurux.Compression.Encoder` |
| `GXV44Decoder` | `TGXV44Decoder` in `Gurux.Compression.Decoder` |
| `GXv44Options` | `TGXV44Options` in `Gurux.Compression.Options` |
| `MaximumStringLength.Value46/78/142/255` | Integer option `46/78/142/255` |
| `Operation` | `TGXV44Operation`, members prefixed `vo`, same numeric values |
| `GXv44Node`, `GXv44DecoderEntry` | `TGXV44Node`, `TGXV44DecoderEntry` records |
| `OnTrace` delegate | `TGXV44TraceEvent` method event, `Sender` and `var Args` |
| Trace `object Value` | Formatted diagnostic `string Value` |
| Node `Type` | Node `Operation` (avoids Pascal's reserved `type`) |
| Read-only collections / root pairs | Detached arrays of records |
| `OperationCanceledException` | `EGXV44Cancelled` |
| `InvalidDataException` | `EGXV44InvalidData` |

No previous Pascal API existed to migrate. Internal .NET implementation types
are not exported as compatibility wrappers.

Assign an object method to `OnTrace` to receive synchronous detached snapshots.
Set `Args.Stop := True` to cancel. The codec is reusable after cancellation or
I/O/format exceptions. A retained snapshot survives reuse, reset and cleanup.
Without a handler, no trace bit strings or event snapshots are created.
`NodeTree`, `StringCollection` and `GetRootArray` return caller-owned copies.
`ClearDiagnostics` discards diagnostic values without invalidating snapshots;
encoder `Reset` also clears the dictionary and restores initial widths.

The encoder's `Compress(UnicodeString)` uses ASCII replacement (`?` for each
non-ASCII UTF-16 code unit), matching the .NET convenience overload. Using
`UnicodeString` explicitly keeps this independent of FPC's native string code
page. Pass encoded `TBytes` for UTF-8 or other encodings.
The decoder's `Decompress(string)` accepts LSB-first binary text and formatting
characters: spaces, CR, LF, hyphens and braces. Incomplete bytes are zero padded
before strict decoding. Trace values are diagnostics, not a serialization API;
the Pascal decoder additionally reports ordinary data-token events.

## Build and test

From PowerShell with a compiler on PATH:

```powershell
./Test.ps1
./Test.ps1 -Compiler Delphi32
./Test.ps1 -Compiler Delphi64
./Test.ps1 -Compiler FPC -Target Win64 # requires FPC's Win64 cross tools
./Test.ps1 -CompilerPath 'C:/path/to/fpc.exe' -Interop
```

`-CompilerPath` also accepts `dcc32.exe` or `dcc64.exe` with the matching
`-Compiler`. Build outputs go under `.build`. The test runner requires no unit
test framework: it checks assertions explicitly and returns a nonzero exit code
on failure. Range/overflow checks are enabled; FPC unit tests additionally run
with heap tracing. Open `Tests/Gurux.Compression.Tests.dproj` in Delphi to run
the same tests. Pass the absolute `Tests/Fixtures` directory as its argument.

For Free Pascal on Linux/macOS, from the repository root:

```sh
mkdir -p .build
fpc -Mdelphi -B -Cr -Co -gl -gh -FuSource -FU.build -FE.build Tests/Gurux.Compression.Tests.dpr
./.build/Gurux.Compression.Tests Tests/Fixtures
```

`-Interop` additionally requires the .NET 10 SDK and the sibling .NET project;
override its location with `-GuruxNetRoot`. It runs 768 bidirectional cases,
including all four string limits, codeword capacities 256/1024/4096/65535,
history limits 512/3072/65536/100000, empty/binary/repetitive inputs and both
array/stream overloads. It checks restored bytes and byte-identical compression.
Ordinary unit tests use frozen independent fixtures without .NET or network
access. See [fixture provenance](Tests/Fixtures/README.md).

## License

GPL-2.0-only or a separate Gurux commercial license. See [LICENSE](LICENSE) and
[commercial license notice](LICENSES/LicenseRef-Gurux-Commercial).
