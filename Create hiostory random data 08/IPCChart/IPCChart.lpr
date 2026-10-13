program IPCChart;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, IPCChartForm, ChartPainter, IPCData, IPCClientPanel, DataGridPanel, ChartFast;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TfrmIPCChart, frmIPCChart);
  Application.Run;
end.
