unit DataGridPanel;

{
  Data grid panel: a table of samples (one row per time stamp, one column
  per data set). The grid is virtual - it holds no data, the host program
  supplies the text of a cell when it is painted (OnGetCell), so even
  hundreds of thousands of rows cost nothing.

  The host calls UpdateRows(Count, Info, ScrollToEnd) whenever its view or
  data changes; rows are numbered 0..Count-1 within that view.
  Double-click on a row -> OnRowDblClick(Row).

  Optional options bar (EnableOptions): visible columns, time format,
  decimals, Boolean style, every Nth sample, font size, coloured values,
  striped rows, grid lines. A host that uses it formats its cells with
  FormatTime / FormatValue and repaints on OnOptionsChange.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, ExtCtrls, StdCtrls, Grids,
  Spin, Menus;

const
  DataGridMaxRows = 200000;   // more rows than this: only the newest are listed

  // value kinds for FormatValue (same order as TDataKind of the programs)
  gkBoolean = 0;
  gkByte = 1;
  gkInteger = 2;
  gkDouble = 3;

type
  TGridCellFunc = function(Row, Col: Integer): string of object;
  TGridRowEvent = procedure(Sender: TObject; Row: Integer) of object;

  TGridTimeFormat = (gtfDateTimeMs, gtfDateTime, gtfTimeMs, gtfIso, gtfNumber, gtfSeconds);
  TGridBoolStyle = (gbsTrueFalse, gbsOneZero, gbsOnOff);

  { TDataGridPanel }

  TDataGridPanel = class(TPanel)
  private
    FGrid: TDrawGrid;
    FTopBar: TPanel;
    FLabel: TLabel;
    FTitles: TStringList;
    FColColors: array of TColor;
    FColVisible: array of Boolean;
    FCount, FOffset, FShown: Integer;
    FOnGetCell: TGridCellFunc;
    FOnRowDblClick: TGridRowEvent;
    FOnOptionsChange: TNotifyEvent;

    // options
    FOptBar: TPanel;
    FBtnOptions: TButton;
    FColMenu: TPopupMenu;
    FCmbTime, FCmbBool: TComboBox;
    FSpnDecimals, FSpnStep, FSpnFont: TSpinEdit;
    FChkColor, FChkStriped, FChkLines: TCheckBox;
    FUpdatingOpts: Boolean;
    FTimeFormat: TGridTimeFormat;
    FBoolStyle: TGridBoolStyle;
    FDecimals, FRowStep, FFontSize: Integer;
    FColorValues, FStriped, FGridLines: Boolean;
    FTimeBase: TDateTime;
    FFS: TFormatSettings;

    procedure GridDrawCell(Sender: TObject; aCol, aRow: Integer; aRect: TRect;
      aState: TGridDrawState);
    procedure GridDblClick(Sender: TObject);
    procedure ApplyColumnWidths;
    procedure ApplyLook;
    procedure OptionsChanged;
    procedure SyncOptionControls;
    procedure BtnOptionsClick(Sender: TObject);
    procedure BtnColumnsClick(Sender: TObject);
    procedure BtnResetClick(Sender: TObject);
    procedure ColMenuClick(Sender: TObject);
    procedure OptControlChange(Sender: TObject);
    function RowToIndex(GridRow: Integer): Integer;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { column titles: usually '#', 'Time', set names }
    procedure SetColumns(const Titles: array of string);
    { text colour per column (clNone = normal), used with "Colour values" }
    procedure SetColumnColors(const Colors: array of TColor);
    procedure UpdateRows(ACount: Integer; const AInfo: string; ScrollToEnd: Boolean);
    { adds the options bar ("Options" button in the header) }
    procedure EnableOptions;
    procedure ResetOptions;
    function FormatTime(T: TDateTime): string;
    function FormatValue(V: Double; Kind: Integer): string;
    property TimeBase: TDateTime read FTimeBase write FTimeBase;   // for "seconds"
    property OnGetCell: TGridCellFunc read FOnGetCell write FOnGetCell;
    property OnRowDblClick: TGridRowEvent read FOnRowDblClick write FOnRowDblClick;
    property OnOptionsChange: TNotifyEvent read FOnOptionsChange write FOnOptionsChange;
  end;

implementation

const
  TimeFormatNames: array[TGridTimeFormat] of string = ('dd/mm/yyyy hh:nn:ss.zzz',
    'dd/mm/yyyy hh:nn:ss', 'hh:nn:ss.zzz', 'yyyy-mm-dd hh:nn:ss.zzz', 'TDateTime number',
    'Seconds from start');
  BoolStyleNames: array[TGridBoolStyle] of string = ('True / False', '1 / 0', 'ON / OFF');

{ TDataGridPanel }

constructor TDataGridPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  FTitles := TStringList.Create;
  FFS := DefaultFormatSettings;
  FFS.DecimalSeparator := '.';
  FRowStep := 1;
  FDecimals := 2;
  FFontSize := 0;          // 0 = default font
  FGridLines := True;

  FTopBar := TPanel.Create(Self);
  FTopBar.Parent := Self;
  FTopBar.Align := alTop;
  FTopBar.Height := 24;
  FTopBar.BevelOuter := bvNone;

  FLabel := TLabel.Create(Self);
  FLabel.Parent := FTopBar;
  FLabel.Align := alClient;
  FLabel.BorderSpacing.Around := 4;
  FLabel.Layout := tlCenter;
  FLabel.Caption := 'Data grid';

  FGrid := TDrawGrid.Create(Self);
  FGrid.Parent := Self;
  FGrid.Align := alClient;
  FGrid.FixedCols := 0;
  FGrid.RowCount := 1;
  FGrid.FixedRows := 1;
  FGrid.ColCount := 2;
  FGrid.DefaultRowHeight := 20;
  FGrid.Options := FGrid.Options + [goRowSelect, goColSizing, goThumbTracking] -
    [goRangeSelect];
  FGrid.OnDrawCell := @GridDrawCell;
  FGrid.OnDblClick := @GridDblClick;
end;

destructor TDataGridPanel.Destroy;
begin
  FTitles.Free;
  inherited Destroy;
end;

procedure TDataGridPanel.SetColumns(const Titles: array of string);
var
  i, OldCount: Integer;
begin
  OldCount := FTitles.Count;
  FTitles.Clear;
  for i := 0 to High(Titles) do
    FTitles.Add(Titles[i]);
  // keep the visible columns when only the names changed
  if Length(FColVisible) <> FTitles.Count then
  begin
    SetLength(FColVisible, FTitles.Count);
    for i := 0 to High(FColVisible) do
      FColVisible[i] := True;
  end;
  if OldCount <> FTitles.Count then
    SetLength(FColColors, 0);
  FGrid.ColCount := Max(1, FTitles.Count);
  ApplyColumnWidths;
  FGrid.Invalidate;
end;

procedure TDataGridPanel.SetColumnColors(const Colors: array of TColor);
var
  i: Integer;
begin
  SetLength(FColColors, Length(Colors));
  for i := 0 to High(Colors) do
    FColColors[i] := Colors[i];
  FGrid.Invalidate;
end;

{ hidden columns get width 0 }
procedure TDataGridPanel.ApplyColumnWidths;
var
  i, W, Scale: Integer;
begin
  if FFontSize > 0 then Scale := FFontSize else Scale := 9;
  for i := 0 to FGrid.ColCount - 1 do
  begin
    case i of
      0: W := 70;
      1: W := 180;
    else
      W := 150;
    end;
    W := Round(W * Scale / 9);
    if (i <= High(FColVisible)) and not FColVisible[i] then W := 0;
    FGrid.ColWidths[i] := W;
  end;
end;

{ font, row height, grid lines }
procedure TDataGridPanel.ApplyLook;
begin
  if FFontSize > 0 then
    FGrid.Font.Size := FFontSize
  else
    FGrid.Font.Size := 0;
  FGrid.DefaultRowHeight := Max(18, FGrid.Canvas.TextHeight('Xg') + 6);
  if FFontSize > 0 then
    FGrid.DefaultRowHeight := Max(18, Round(FFontSize * 1.9) + 4);
  if FGridLines then
    FGrid.Options := FGrid.Options + [goVertLine, goHorzLine, goFixedVertLine, goFixedHorzLine]
  else
    FGrid.Options := FGrid.Options - [goVertLine, goHorzLine];
  ApplyColumnWidths;
end;

function TDataGridPanel.RowToIndex(GridRow: Integer): Integer;
begin
  Result := FOffset + (GridRow - 1) * FRowStep;
end;

procedure TDataGridPanel.UpdateRows(ACount: Integer; const AInfo: string;
  ScrollToEnd: Boolean);
var
  Rows: Integer;
  Info: string;
begin
  FCount := Max(0, ACount);
  // every Nth sample, newest rows when there are too many
  Rows := (FCount + FRowStep - 1) div FRowStep;
  FShown := Min(Rows, DataGridMaxRows);
  // the last listed row is always the newest sample
  if FShown > 0 then
    FOffset := Max(0, FCount - 1 - (FShown - 1) * FRowStep)
  else
    FOffset := 0;
  Info := AInfo;
  if FRowStep > 1 then
    Info := Info + Format('   (every %d. sample: %d rows)', [FRowStep, FShown]);
  if FShown < Rows then
    Info := Info + Format('   (only the newest %d rows listed - zoom in to see all)', [FShown]);
  FLabel.Caption := Info;
  if FGrid.RowCount <> 1 + FShown then
    FGrid.RowCount := 1 + FShown;
  if ScrollToEnd and (FShown > 0) then
    FGrid.TopRow := Max(1, FGrid.RowCount - FGrid.VisibleRowCount);
  FGrid.Invalidate;
end;

procedure TDataGridPanel.GridDrawCell(Sender: TObject; aCol, aRow: Integer;
  aRect: TRect; aState: TGridDrawState);
var
  S: string;
  TS: TTextStyle;
  Selected: Boolean;
  Back: TColor;
begin
  if (aCol <= High(FColVisible)) and not FColVisible[aCol] then Exit;
  Selected := (aRow > 0) and (gdSelected in aState);
  if aRow = 0 then
  begin
    if aCol < FTitles.Count then S := FTitles[aCol] else S := '';
  end
  else
  begin
    // striped rows
    if FStriped and not Selected and Odd(aRow) then
    begin
      Back := ColorToRGB(FGrid.Color);
      Back := RGBToColor(Max(0, Red(Back) - 14), Max(0, Green(Back) - 10), Max(0, Blue(Back) - 4));
      FGrid.Canvas.Brush.Color := Back;
      FGrid.Canvas.FillRect(aRect);
    end;
    if Assigned(FOnGetCell) then
      S := FOnGetCell(RowToIndex(aRow), aCol)
    else
      S := '';
    // value in the colour of its data set
    if FColorValues and not Selected and (aCol <= High(FColColors)) and
       (FColColors[aCol] <> clNone) then
      FGrid.Canvas.Font.Color := FColColors[aCol];
  end;
  TS := FGrid.Canvas.TextStyle;
  TS.Layout := tlCenter;
  // numbers right, text left
  if (aRow > 0) and (aCol <> 1) then TS.Alignment := taRightJustify
  else TS.Alignment := taLeftJustify;
  FGrid.Canvas.TextRect(Rect(aRect.Left + 4, aRect.Top, aRect.Right - 4, aRect.Bottom),
    aRect.Left + 4, aRect.Top, S, TS);
end;

procedure TDataGridPanel.GridDblClick(Sender: TObject);
begin
  if (FGrid.Row >= 1) and Assigned(FOnRowDblClick) then
    FOnRowDblClick(Self, RowToIndex(FGrid.Row));
end;

{ ---------- formatting ---------- }

function TDataGridPanel.FormatTime(T: TDateTime): string;
begin
  case FTimeFormat of
    gtfDateTime: Result := FormatDateTime('dd/mm/yyyy hh:nn:ss', T);
    gtfTimeMs: Result := FormatDateTime('hh:nn:ss.zzz', T);
    gtfIso: Result := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', T);
    gtfNumber: Result := FormatFloat('0.0000000000', T, FFS);
    gtfSeconds: Result := FormatFloat('0.000', (T - FTimeBase) * SecsPerDay, FFS) + ' s';
  else
    Result := FormatDateTime('dd/mm/yyyy hh:nn:ss.zzz', T);
  end;
end;

function TDataGridPanel.FormatValue(V: Double; Kind: Integer): string;
begin
  if IsNan(V) then Exit('-');
  case Kind of
    gkBoolean:
      case FBoolStyle of
        gbsOneZero: if V >= 0.5 then Result := '1' else Result := '0';
        gbsOnOff: if V >= 0.5 then Result := 'ON' else Result := 'OFF';
      else
        if V >= 0.5 then Result := 'True' else Result := 'False';
      end;
    gkByte, gkInteger: Result := IntToStr(Round(V));
  else
    Result := FloatToStrF(V, ffFixed, 15, FDecimals, FFS);
  end;
end;

{ ---------- options bar ---------- }

procedure TDataGridPanel.EnableOptions;
var
  B: TButton;
  T: TGridTimeFormat;
  BS: TGridBoolStyle;

  function AddLabel(X, Y: Integer; const ACaption: string): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := FOptBar;
    Result.SetBounds(X, Y + 4, 60, 18);
    Result.Caption := ACaption;
  end;

  function AddSpin(X, Y, W, AMin, AMax: Integer; const AHint: string): TSpinEdit;
  begin
    Result := TSpinEdit.Create(Self);
    Result.Parent := FOptBar;
    Result.SetBounds(X, Y, W, 24);
    Result.MinValue := AMin;
    Result.MaxValue := AMax;
    Result.Hint := AHint;
    Result.ShowHint := True;
    Result.OnChange := @OptControlChange;
  end;

  function AddCheck(X, Y, W: Integer; const ACaption: string): TCheckBox;
  begin
    Result := TCheckBox.Create(Self);
    Result.Parent := FOptBar;
    Result.SetBounds(X, Y + 2, W, 20);
    Result.Caption := ACaption;
    Result.OnChange := @OptControlChange;
  end;

begin
  if FOptBar <> nil then Exit;

  FBtnOptions := TButton.Create(Self);
  FBtnOptions.Parent := FTopBar;
  FBtnOptions.Align := alRight;
  FBtnOptions.Width := 110;
  FBtnOptions.Caption := 'Options...';
  FBtnOptions.Hint := 'Columns, time format, decimals, font, colours ...';
  FBtnOptions.ShowHint := True;
  FBtnOptions.OnClick := @BtnOptionsClick;
  FTopBar.Height := 28;

  FOptBar := TPanel.Create(Self);
  FOptBar.Parent := Self;
  FOptBar.Align := alTop;
  FOptBar.Top := FTopBar.Top + FTopBar.Height;
  FOptBar.Height := 64;
  FOptBar.BevelOuter := bvLowered;
  FOptBar.Visible := False;

  FColMenu := TPopupMenu.Create(Self);

  // row 1
  B := TButton.Create(Self);
  B.Parent := FOptBar;
  B.SetBounds(6, 4, 90, 26);
  B.Caption := 'Columns...';
  B.Hint := 'Show / hide columns';
  B.ShowHint := True;
  B.OnClick := @BtnColumnsClick;

  AddLabel(106, 4, 'Time');
  FCmbTime := TComboBox.Create(Self);
  FCmbTime.Parent := FOptBar;
  FCmbTime.SetBounds(140, 4, 180, 24);
  FCmbTime.Style := csDropDownList;
  for T := Low(TGridTimeFormat) to High(TGridTimeFormat) do
    FCmbTime.Items.Add(TimeFormatNames[T]);
  FCmbTime.OnChange := @OptControlChange;

  AddLabel(332, 4, 'Decimals');
  FSpnDecimals := AddSpin(390, 4, 50, 0, 6, 'Decimal places of Double values');

  AddLabel(452, 4, 'Boolean');
  FCmbBool := TComboBox.Create(Self);
  FCmbBool.Parent := FOptBar;
  FCmbBool.SetBounds(506, 4, 100, 24);
  FCmbBool.Style := csDropDownList;
  for BS := Low(TGridBoolStyle) to High(TGridBoolStyle) do
    FCmbBool.Items.Add(BoolStyleNames[BS]);
  FCmbBool.OnChange := @OptControlChange;

  AddLabel(618, 4, 'Every');
  FSpnStep := AddSpin(658, 4, 70, 1, 1000, 'Show every Nth sample (1 = all)');
  AddLabel(734, 4, '. sample');

  // row 2
  AddLabel(6, 34, 'Font size');
  FSpnFont := AddSpin(66, 34, 50, 6, 20, 'Font size of the table');
  FChkColor := AddCheck(130, 34, 160, 'Values in set colour');
  FChkStriped := AddCheck(296, 34, 110, 'Striped rows');
  FChkLines := AddCheck(412, 34, 100, 'Grid lines');

  B := TButton.Create(Self);
  B.Parent := FOptBar;
  B.SetBounds(530, 33, 90, 26);
  B.Caption := 'Reset';
  B.Hint := 'Default grid options';
  B.ShowHint := True;
  B.OnClick := @BtnResetClick;

  FFontSize := 9;
  SyncOptionControls;
  ApplyLook;
end;

procedure TDataGridPanel.SyncOptionControls;
begin
  if FOptBar = nil then Exit;
  FUpdatingOpts := True;
  try
    FCmbTime.ItemIndex := Ord(FTimeFormat);
    FCmbBool.ItemIndex := Ord(FBoolStyle);
    FSpnDecimals.Value := FDecimals;
    FSpnStep.Value := FRowStep;
    FSpnFont.Value := FFontSize;
    FChkColor.Checked := FColorValues;
    FChkStriped.Checked := FStriped;
    FChkLines.Checked := FGridLines;
  finally
    FUpdatingOpts := False;
  end;
end;

procedure TDataGridPanel.ResetOptions;
var
  i: Integer;
begin
  FTimeFormat := gtfDateTimeMs;
  FBoolStyle := gbsTrueFalse;
  FDecimals := 2;
  FRowStep := 1;
  FFontSize := 9;
  FColorValues := False;
  FStriped := False;
  FGridLines := True;
  for i := 0 to High(FColVisible) do
    FColVisible[i] := True;
  SyncOptionControls;
  OptionsChanged;
end;

procedure TDataGridPanel.OptionsChanged;
begin
  ApplyLook;
  FGrid.Invalidate;
  if Assigned(FOnOptionsChange) then FOnOptionsChange(Self);
end;

procedure TDataGridPanel.OptControlChange(Sender: TObject);
var
  OldStep: Integer;
begin
  if FUpdatingOpts then Exit;
  OldStep := FRowStep;
  if FCmbTime.ItemIndex >= 0 then FTimeFormat := TGridTimeFormat(FCmbTime.ItemIndex);
  if FCmbBool.ItemIndex >= 0 then FBoolStyle := TGridBoolStyle(FCmbBool.ItemIndex);
  FDecimals := FSpnDecimals.Value;
  FRowStep := Max(1, FSpnStep.Value);
  FFontSize := FSpnFont.Value;
  FColorValues := FChkColor.Checked;
  FStriped := FChkStriped.Checked;
  FGridLines := FChkLines.Checked;
  if FRowStep <> OldStep then
    UpdateRows(FCount, '', False);   // host refreshes the info text via OnOptionsChange
  OptionsChanged;
end;

procedure TDataGridPanel.BtnOptionsClick(Sender: TObject);
begin
  FOptBar.Visible := not FOptBar.Visible;
  if FOptBar.Visible then
  begin
    FOptBar.Top := FTopBar.Top + FTopBar.Height;
    FBtnOptions.Caption := 'Hide options';
  end
  else
    FBtnOptions.Caption := 'Options...';
end;

procedure TDataGridPanel.BtnColumnsClick(Sender: TObject);
var
  i: Integer;
  Item: TMenuItem;
  P: TPoint;
begin
  FColMenu.Items.Clear;
  for i := 0 to FTitles.Count - 1 do
  begin
    Item := TMenuItem.Create(FColMenu);
    Item.Caption := FTitles[i];
    Item.Checked := (i > High(FColVisible)) or FColVisible[i];
    Item.Tag := i;
    Item.OnClick := @ColMenuClick;
    FColMenu.Items.Add(Item);
  end;
  P := TControl(Sender).ClientToScreen(Point(0, TControl(Sender).Height));
  FColMenu.PopUp(P.X, P.Y);
end;

procedure TDataGridPanel.ColMenuClick(Sender: TObject);
var
  i, n, Vis: Integer;
begin
  i := TMenuItem(Sender).Tag;
  if i > High(FColVisible) then Exit;
  // keep at least one column
  Vis := 0;
  for n := 0 to High(FColVisible) do
    if FColVisible[n] then Inc(Vis);
  if FColVisible[i] and (Vis <= 1) then Exit;
  FColVisible[i] := not FColVisible[i];
  OptionsChanged;
end;

procedure TDataGridPanel.BtnResetClick(Sender: TObject);
begin
  ResetOptions;
  UpdateRows(FCount, '', False);
  if Assigned(FOnOptionsChange) then FOnOptionsChange(Self);
end;

end.
