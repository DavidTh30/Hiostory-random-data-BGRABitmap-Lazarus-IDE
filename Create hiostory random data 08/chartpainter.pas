unit ChartPainter;

{
  Small drawing layer for the chart, so the same chart code can paint
  - on a TBGRABitmap (screen and PNG export), or
  - into an SVG document (vector export).
  Coordinates are pixels; text Y is the top of the text, like TextOut.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Graphics, BGRABitmap, BGRABitmapTypes;

const
  ChartFontName = 'Segoe UI';
  ChartFontHeight = 13;

type
  { TChartPainter }

  TChartPainter = class
  public
    procedure FillRect(X1, Y1, X2, Y2: Single; C: TBGRAPixel); virtual; abstract;
    procedure HLine(X1, X2, Y: Integer; C: TBGRAPixel); virtual; abstract;
    procedure VLine(X, Y1, Y2: Integer; C: TBGRAPixel); virtual; abstract;
    procedure Line(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single;
      Style: TPenStyle = psSolid); virtual; abstract;
    procedure Polyline(const Pts: array of TPointF; C: TBGRAPixel; W: Single;
      Style: TPenStyle = psSolid); virtual; abstract;
    procedure Frame(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single = 1); virtual; abstract;
    procedure Circle(X, Y, R: Single; Fill, Stroke: TBGRAPixel; StrokeW: Single); virtual; abstract;
    procedure RoundRect(X1, Y1, X2, Y2, Radius: Single; C: TBGRAPixel); virtual; abstract;
    procedure Text(X, Y: Single; const S: string; C: TBGRAPixel;
      Align: TAlignment = taLeftJustify); virtual; abstract;
    function TextWidth(const S: string): Single; virtual; abstract;
    procedure Clip(const R: TRect); virtual; abstract;
    procedure NoClip; virtual; abstract;
  end;

  { TBGRAChartPainter - raster, antialiased }

  TBGRAChartPainter = class(TChartPainter)
  private
    FBmp: TBGRABitmap;
  public
    constructor Create(ABmp: TBGRABitmap);
    procedure FillRect(X1, Y1, X2, Y2: Single; C: TBGRAPixel); override;
    procedure HLine(X1, X2, Y: Integer; C: TBGRAPixel); override;
    procedure VLine(X, Y1, Y2: Integer; C: TBGRAPixel); override;
    procedure Line(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single;
      Style: TPenStyle = psSolid); override;
    procedure Polyline(const Pts: array of TPointF; C: TBGRAPixel; W: Single;
      Style: TPenStyle = psSolid); override;
    procedure Frame(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single = 1); override;
    procedure Circle(X, Y, R: Single; Fill, Stroke: TBGRAPixel; StrokeW: Single); override;
    procedure RoundRect(X1, Y1, X2, Y2, Radius: Single; C: TBGRAPixel); override;
    procedure Text(X, Y: Single; const S: string; C: TBGRAPixel;
      Align: TAlignment = taLeftJustify); override;
    function TextWidth(const S: string): Single; override;
    procedure Clip(const R: TRect); override;
    procedure NoClip; override;
    property Bitmap: TBGRABitmap read FBmp;
  end;

  { TSVGChartPainter - vector, writes SVG 1.1 }

  TSVGChartPainter = class(TChartPainter)
  private
    FSL: TStringList;
    FMeasure: TBGRABitmap;    // only used to measure text widths
    FFS: TFormatSettings;
    FWidth, FHeight: Integer;
    FClipCount: Integer;
    FClipOpen: Boolean;
    function N(V: Single): string;
    function Col(C: TBGRAPixel; const Attr: string): string;
    function Dash(Style: TPenStyle; W: Single): string;
  public
    constructor Create(AWidth, AHeight: Integer);
    destructor Destroy; override;
    procedure FillRect(X1, Y1, X2, Y2: Single; C: TBGRAPixel); override;
    procedure HLine(X1, X2, Y: Integer; C: TBGRAPixel); override;
    procedure VLine(X, Y1, Y2: Integer; C: TBGRAPixel); override;
    procedure Line(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single;
      Style: TPenStyle = psSolid); override;
    procedure Polyline(const Pts: array of TPointF; C: TBGRAPixel; W: Single;
      Style: TPenStyle = psSolid); override;
    procedure Frame(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single = 1); override;
    procedure Circle(X, Y, R: Single; Fill, Stroke: TBGRAPixel; StrokeW: Single); override;
    procedure RoundRect(X1, Y1, X2, Y2, Radius: Single; C: TBGRAPixel); override;
    procedure Text(X, Y: Single; const S: string; C: TBGRAPixel;
      Align: TAlignment = taLeftJustify); override;
    function TextWidth(const S: string): Single; override;
    procedure Clip(const R: TRect); override;
    procedure NoClip; override;
    procedure SaveToFile(const AFileName: string);
  end;

implementation

function XmlEscape(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

{ TBGRAChartPainter }

constructor TBGRAChartPainter.Create(ABmp: TBGRABitmap);
begin
  inherited Create;
  FBmp := ABmp;
  FBmp.FontName := ChartFontName;
  FBmp.FontHeight := ChartFontHeight;
  FBmp.FontQuality := fqSystemClearType;
end;

procedure TBGRAChartPainter.FillRect(X1, Y1, X2, Y2: Single; C: TBGRAPixel);
begin
  FBmp.FillRect(Round(X1), Round(Y1), Round(X2), Round(Y2), C, dmDrawWithTransparency);
end;

procedure TBGRAChartPainter.HLine(X1, X2, Y: Integer; C: TBGRAPixel);
begin
  FBmp.DrawHorizLine(X1, Y, X2, C);
end;

procedure TBGRAChartPainter.VLine(X, Y1, Y2: Integer; C: TBGRAPixel);
begin
  FBmp.DrawVertLine(X, Y1, Y2, C);
end;

procedure TBGRAChartPainter.Line(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single;
  Style: TPenStyle);
begin
  FBmp.PenStyle := Style;
  FBmp.DrawLineAntialias(X1, Y1, X2, Y2, C, W);
  FBmp.PenStyle := psSolid;
end;

procedure TBGRAChartPainter.Polyline(const Pts: array of TPointF; C: TBGRAPixel;
  W: Single; Style: TPenStyle);
begin
  if Length(Pts) < 2 then Exit;
  FBmp.PenStyle := Style;
  FBmp.DrawPolyLineAntialias(Pts, C, W);
  FBmp.PenStyle := psSolid;
end;

procedure TBGRAChartPainter.Frame(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single);
begin
  if W <= 1 then
    FBmp.Rectangle(Round(X1), Round(Y1), Round(X2), Round(Y2), C, dmDrawWithTransparency)
  else
    FBmp.RectangleAntialias(X1, Y1, X2, Y2, C, W);
end;

procedure TBGRAChartPainter.Circle(X, Y, R: Single; Fill, Stroke: TBGRAPixel;
  StrokeW: Single);
begin
  if Fill.alpha > 0 then
    FBmp.FillEllipseAntialias(X, Y, R, R, Fill);
  if (Stroke.alpha > 0) and (StrokeW > 0) then
    FBmp.EllipseAntialias(X, Y, R, R, Stroke, StrokeW);
end;

procedure TBGRAChartPainter.RoundRect(X1, Y1, X2, Y2, Radius: Single; C: TBGRAPixel);
begin
  FBmp.FillRoundRectAntialias(X1, Y1, X2, Y2, Radius, Radius, C);
end;

procedure TBGRAChartPainter.Text(X, Y: Single; const S: string; C: TBGRAPixel;
  Align: TAlignment);
begin
  FBmp.TextOut(X, Y, S, C, Align);
end;

function TBGRAChartPainter.TextWidth(const S: string): Single;
begin
  Result := FBmp.TextSize(S).cx;
end;

procedure TBGRAChartPainter.Clip(const R: TRect);
begin
  FBmp.ClipRect := R;
end;

procedure TBGRAChartPainter.NoClip;
begin
  FBmp.NoClip;
end;

{ TSVGChartPainter }

constructor TSVGChartPainter.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FFS := DefaultFormatSettings;
  FFS.DecimalSeparator := '.';
  FMeasure := TBGRABitmap.Create(1, 1);
  FMeasure.FontName := ChartFontName;
  FMeasure.FontHeight := ChartFontHeight;
  FSL := TStringList.Create;
  FSL.Add('<?xml version="1.0" encoding="UTF-8" standalone="no"?>');
  FSL.Add(Format('<svg xmlns="http://www.w3.org/2000/svg" version="1.1" ' +
    'width="%d" height="%d" viewBox="0 0 %d %d" ' +
    'font-family="%s, Arial, sans-serif" font-size="%dpx">',
    [AWidth, AHeight, AWidth, AHeight, ChartFontName, ChartFontHeight]));
end;

destructor TSVGChartPainter.Destroy;
begin
  FMeasure.Free;
  FSL.Free;
  inherited Destroy;
end;

function TSVGChartPainter.N(V: Single): string;
begin
  Result := FormatFloat('0.##', V, FFS);
end;

{ ' fill="#rrggbb" fill-opacity="0.5"' }
function TSVGChartPainter.Col(C: TBGRAPixel; const Attr: string): string;
begin
  Result := Format(' %s="#%.2x%.2x%.2x"', [Attr, C.red, C.green, C.blue]);
  if C.alpha < 255 then
    Result := Result + Format(' %s-opacity="%s"', [Attr, N(C.alpha / 255)]);
end;

{ Same dash patterns as BGRABitmap, scaled with the line width }
function TSVGChartPainter.Dash(Style: TPenStyle; W: Single): string;
const
  P3 = 3; P1 = 1;
var
  Pat: array of Single;
  i: Integer;
begin
  Result := '';
  case Style of
    psDash: Pat := [P3, P1];
    psDot: Pat := [P1, P1];
    psDashDot: Pat := [P3, P1, P1, P1];
    psDashDotDot: Pat := [P3, P1, P1, P1, P1, P1];
  else
    Exit;
  end;
  Result := ' stroke-dasharray="';
  for i := 0 to High(Pat) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + N(Pat[i] * W);
  end;
  Result := Result + '"';
end;

procedure TSVGChartPainter.FillRect(X1, Y1, X2, Y2: Single; C: TBGRAPixel);
begin
  FSL.Add(Format('<rect x="%s" y="%s" width="%s" height="%s"%s/>',
    [N(X1), N(Y1), N(X2 - X1), N(Y2 - Y1), Col(C, 'fill')]));
end;

procedure TSVGChartPainter.HLine(X1, X2, Y: Integer; C: TBGRAPixel);
begin
  // a 1 px pixel row, like DrawHorizLine
  FSL.Add(Format('<line x1="%d" y1="%s" x2="%d" y2="%s"%s stroke-width="1"/>',
    [X1, N(Y + 0.5), X2 + 1, N(Y + 0.5), Col(C, 'stroke')]));
end;

procedure TSVGChartPainter.VLine(X, Y1, Y2: Integer; C: TBGRAPixel);
begin
  FSL.Add(Format('<line x1="%s" y1="%d" x2="%s" y2="%d"%s stroke-width="1"/>',
    [N(X + 0.5), Y1, N(X + 0.5), Y2 + 1, Col(C, 'stroke')]));
end;

procedure TSVGChartPainter.Line(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single;
  Style: TPenStyle);
begin
  FSL.Add(Format('<line x1="%s" y1="%s" x2="%s" y2="%s"%s stroke-width="%s"%s/>',
    [N(X1), N(Y1), N(X2), N(Y2), Col(C, 'stroke'), N(W), Dash(Style, W)]));
end;

procedure TSVGChartPainter.Polyline(const Pts: array of TPointF; C: TBGRAPixel;
  W: Single; Style: TPenStyle);
var
  S: string;
  i: Integer;
begin
  if Length(Pts) < 2 then Exit;
  S := '';
  for i := 0 to High(Pts) do
  begin
    if i > 0 then S := S + ' ';
    S := S + N(Pts[i].X) + ',' + N(Pts[i].Y);
  end;
  FSL.Add(Format('<polyline fill="none"%s stroke-width="%s" stroke-linejoin="round"%s points="%s"/>',
    [Col(C, 'stroke'), N(W), Dash(Style, W), S]));
end;

procedure TSVGChartPainter.Frame(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single);
begin
  FSL.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" fill="none"%s stroke-width="%s"/>',
    [N(X1 + 0.5), N(Y1 + 0.5), N(X2 - X1 - 1), N(Y2 - Y1 - 1), Col(C, 'stroke'), N(W)]));
end;

procedure TSVGChartPainter.Circle(X, Y, R: Single; Fill, Stroke: TBGRAPixel;
  StrokeW: Single);
var
  S: string;
begin
  S := Format('<circle cx="%s" cy="%s" r="%s"', [N(X), N(Y), N(R)]);
  if Fill.alpha > 0 then S := S + Col(Fill, 'fill') else S := S + ' fill="none"';
  if (Stroke.alpha > 0) and (StrokeW > 0) then
    S := S + Col(Stroke, 'stroke') + ' stroke-width="' + N(StrokeW) + '"';
  FSL.Add(S + '/>');
end;

procedure TSVGChartPainter.RoundRect(X1, Y1, X2, Y2, Radius: Single; C: TBGRAPixel);
begin
  FSL.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" rx="%s"%s/>',
    [N(X1), N(Y1), N(X2 - X1), N(Y2 - Y1), N(Radius), Col(C, 'fill')]));
end;

procedure TSVGChartPainter.Text(X, Y: Single; const S: string; C: TBGRAPixel;
  Align: TAlignment);
const
  Anchor: array[TAlignment] of string = ('start', 'end', 'middle');
begin
  // Y is the top of the text; SVG wants the baseline
  FSL.Add(Format('<text x="%s" y="%s" text-anchor="%s"%s>%s</text>',
    [N(X), N(Y + ChartFontHeight * 0.95), Anchor[Align], Col(C, 'fill'), XmlEscape(S)]));
end;

function TSVGChartPainter.TextWidth(const S: string): Single;
begin
  Result := FMeasure.TextSize(S).cx;
end;

procedure TSVGChartPainter.Clip(const R: TRect);
begin
  NoClip;
  Inc(FClipCount);
  FSL.Add(Format('<clipPath id="clip%d"><rect x="%d" y="%d" width="%d" height="%d"/></clipPath>',
    [FClipCount, R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top]));
  FSL.Add(Format('<g clip-path="url(#clip%d)">', [FClipCount]));
  FClipOpen := True;
end;

procedure TSVGChartPainter.NoClip;
begin
  if FClipOpen then
    FSL.Add('</g>');
  FClipOpen := False;
end;

procedure TSVGChartPainter.SaveToFile(const AFileName: string);
begin
  NoClip;
  FSL.Add('</svg>');
  try
    FSL.SaveToFile(AFileName);
  finally
    FSL.Delete(FSL.Count - 1);
  end;
end;

end.
