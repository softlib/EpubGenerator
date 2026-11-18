program EpubBuilderGUI;

{$APPTYPE GUI}

uses
  Vcl.Forms,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  MainForm in 'MainForm.pas';

var
  MainForm: TMainForm;
  IsSelfTest: Boolean;
  I: Integer;
begin
  IsSelfTest := False;
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), '--selftest') then
      IsSelfTest := True;

  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'EPUB 可视化构建器';

  if IsSelfTest then
    TMainForm.RunSelfTest
  else
  begin
    Application.CreateForm(TMainForm, MainForm);
    MainForm.Show;  // CreateNew 构造的窗体需手动显示
    Application.Run;
  end;
end.
