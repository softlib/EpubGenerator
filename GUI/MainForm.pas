unit MainForm;

{==============================================================================
  MainForm.pas —— EPUB 可视化构建器主窗体

  纯代码创建全部 VCL 控件（不依赖 DFM），复用 EpubGenerator.pas 完成打包。
  功能：元数据编辑 / 章节层级管理 / 音视频图片样式字体资源 / SMIL 关联 /
        占位符插入 / 一键构建与日志 / 示例项目 / 无人值守自检。
==============================================================================}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  System.DateUtils,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ComCtrls,
  Vcl.Dialogs,
  Vcl.ExtCtrls,
  Vcl.Graphics,
  Winapi.Messages,
  Winapi.Windows,
  Winapi.ShellAPI,
  System.Zip,
  System.UITypes,
  EpubGenerator;

type
  { 界面层章节，Id 为用户可见的稳定标识，构建时传给生成器 }
  TGuiChapter = class
  public
    Id: string;
    Title: string;
    Content: string;
    FileName: string;
    Level: Integer;
    Parent: TGuiChapter;
    InToc: Boolean;
    IsCover: Boolean;
    SmilResourceId: string;
    constructor Create(const AId: string);
  end;

  { 界面层资源 }
  TGuiResource = class
  public
    Id: string;
    Kind: TEpubAssetKind;
    SourceFile: string;
    ArchiveName: string;
    MimeType: string;
    IsCover: Boolean;
    constructor Create(const AId: string);
    function KindName: string;
  end;

  TMainForm = class(TForm)
  private
    FChapters: TObjectList<TGuiChapter>;
    FResources: TObjectList<TGuiResource>;
    FIdCounter: Integer;
    FLoading: Boolean;

    FPageControl: TPageControl;
    FStatusBar: TStatusBar;

    { 元数据页 }
    FEdTitle: TEdit;
    FEdAuthor: TEdit;
    FEdLanguage: TEdit;
    FEdIdentifier: TEdit;
    FEdPublisher: TEdit;
    FEdSubject: TEdit;
    FEdDate: TEdit;
    FEdRights: TEdit;
    FMemoDescription: TMemo;

    { 章节页 }
    FChapterList: TListBox;
    FEdChapterTitle: TEdit;
    FEdChapterFile: TEdit;
    FCboLevel: TComboBox;
    FCboParent: TComboBox;
    FCboSmil: TComboBox;
    FChkInToc: TCheckBox;
    FChkCoverChapter: TCheckBox;
    FMemoContent: TMemo;

    { 资源页 }
    FResourceList: TListView;

    { 构建页 }
    FEdOutput: TEdit;
    FChkGenerateNcx: TCheckBox;
    FChkAutoLinkStyles: TCheckBox;
    FLogMemo: TMemo;

    procedure BuildUi;
    procedure CreateMetaTab(APage: TTabSheet);
    procedure CreateChapterTab(APage: TTabSheet);
    procedure CreateResourceTab(APage: TTabSheet);
    procedure CreateBuildTab(APage: TTabSheet);

    function NewId(const APrefix: string): string;
    function CurrentChapter: TGuiChapter;
    function CurrentResource: TGuiResource;

    procedure RefreshChapterList;
    procedure RefreshParentCombo;
    procedure RefreshSmilCombo;
    procedure LoadChapterToEditor;
    procedure SaveEditorToChapter(Sender: TObject);
    procedure EditorChanged(Sender: TObject);

    procedure RefreshResourceList;

    procedure Log(const S: string);
    procedure SetStatus(const S: string);

    procedure BtnAddChapterClick(Sender: TObject);
    procedure BtnDeleteChapterClick(Sender: TObject);
    procedure BtnMoveUpClick(Sender: TObject);
    procedure BtnMoveDownClick(Sender: TObject);
    procedure ChapterListClick(Sender: TObject);

    procedure BtnInsertAudioClick(Sender: TObject);
    procedure BtnInsertVideoClick(Sender: TObject);
    procedure BtnInsertImageClick(Sender: TObject);
    procedure BtnInsertLinkClick(Sender: TObject);
    procedure InsertToken(const AToken: string);

    procedure BtnAddResourceClick(Sender: TObject);
    procedure BtnSetCoverClick(Sender: TObject);
    procedure BtnDeleteResourceClick(Sender: TObject);
    procedure BtnOpenSourceClick(Sender: TObject);
    procedure ResourceListClick(Sender: TObject);

    procedure BtnBrowseOutputClick(Sender: TObject);
    procedure BtnBuildClick(Sender: TObject);
    procedure BtnLoadSampleClick(Sender: TObject);
    procedure BtnClearClick(Sender: TObject);

    function SelectFromList(const ACaption: string; const AItems: TStrings;
      out AIndex: Integer): Boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure LoadSample(ASilent: Boolean);
    function BuildEpub(const AOutputFile: string): Boolean;
    class procedure RunSelfTest;
  end;

implementation

{------------------------------------------------------------------------------
  辅助函数
------------------------------------------------------------------------------}

function MakeLabel(AOwner: TComponent; AParent: TWinControl;
  const AText: string; X, Y, W: Integer): TLabel;
begin
  Result := TLabel.Create(AOwner);
  Result.Parent := AParent;
  Result.Caption := AText;
  Result.Left := X;
  Result.Top := Y + 3;
  Result.Width := W;
end;

function MakeEdit(AOwner: TComponent; AParent: TWinControl;
  X, Y, W: Integer; const AText: string = ''): TEdit;
begin
  Result := TEdit.Create(AOwner);
  Result.Parent := AParent;
  Result.Left := X;
  Result.Top := Y;
  Result.Width := W;
  Result.Text := AText;
end;

function MakeButton(AOwner: TComponent; AParent: TWinControl;
  const ACaption: string; X, Y, W, H: Integer;
  AOnClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(AOwner);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Left := X;
  Result.Top := Y;
  Result.Width := W;
  Result.Height := H;
  Result.OnClick := AOnClick;
end;

function MakeCheckBox(AOwner: TComponent; AParent: TWinControl;
  const ACaption: string; X, Y, W: Integer; AChecked: Boolean): TCheckBox;
begin
  Result := TCheckBox.Create(AOwner);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Left := X;
  Result.Top := Y;
  Result.Width := W;
  Result.Checked := AChecked;
end;

{------------------------------------------------------------------------------
  TGuiChapter / TGuiResource
------------------------------------------------------------------------------}

constructor TGuiChapter.Create(const AId: string);
begin
  inherited Create;
  Id := AId;
  Title := '新章节';
  FileName := '';
  Level := 1;
  InToc := True;
  IsCover := False;
end;

constructor TGuiResource.Create(const AId: string);
begin
  inherited Create;
  Id := AId;
  Kind := akOther;
end;

function TGuiResource.KindName: string;
begin
  case Kind of
    akImage: Result := '图片';
    akAudio: Result := '音频';
    akVideo: Result := '视频';
    akStyle: Result := '样式';
    akFont:  Result := '字体';
    akSmil:  Result := 'SMIL';
  else
    Result := '其他';
  end;
end;

{------------------------------------------------------------------------------
  构造 / 析构
------------------------------------------------------------------------------}

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner, 0);  // 纯代码创建，不加载 DFM 资源
  Caption := 'EPUB 可视化构建器  —  Delphi 12.2 + System.Zip';
  Width := 1120;
  Height := 760;
  Position := poScreenCenter;

  FChapters := TObjectList<TGuiChapter>.Create(True);
  FResources := TObjectList<TGuiResource>.Create(True);
  FIdCounter := 0;
  FLoading := False;

  BuildUi;
  LoadSample(True);
end;

destructor TMainForm.Destroy;
begin
  FResources.Free;
  FChapters.Free;
  inherited Destroy;
end;

function TMainForm.NewId(const APrefix: string): string;
begin
  Inc(FIdCounter);
  Result := APrefix + Format('%.3d', [FIdCounter]);
end;

{------------------------------------------------------------------------------
  界面搭建
------------------------------------------------------------------------------}

procedure TMainForm.BuildUi;
var
  Page: TTabSheet;
begin
  FPageControl := TPageControl.Create(Self);
  FPageControl.Parent := Self;
  FPageControl.Align := alClient;

  FStatusBar := TStatusBar.Create(Self);
  FStatusBar.Parent := Self;
  FStatusBar.Align := alBottom;
  FStatusBar.Panels.Add.Width := 400;
  FStatusBar.Panels.Add.Width := 300;
  FStatusBar.Panels.Add.Width := 300;

  Page := TTabSheet.Create(Self);
  Page.PageControl := FPageControl;
  Page.Caption := '基本信息';
  CreateMetaTab(Page);

  Page := TTabSheet.Create(Self);
  Page.PageControl := FPageControl;
  Page.Caption := '章节管理';
  CreateChapterTab(Page);

  Page := TTabSheet.Create(Self);
  Page.PageControl := FPageControl;
  Page.Caption := '资源管理';
  CreateResourceTab(Page);

  Page := TTabSheet.Create(Self);
  Page.PageControl := FPageControl;
  Page.Caption := '构建与日志';
  CreateBuildTab(Page);

  SetStatus('就绪');
end;

procedure TMainForm.CreateMetaTab(APage: TTabSheet);
var
  P: TPanel;
begin
  P := TPanel.Create(Self);
  P.Parent := APage;
  P.Align := alClient;
  P.BevelOuter := bvNone;
  P.Padding.SetBounds(16, 16, 16, 16);

  MakeLabel(Self, P, '书名 *', 16, 20, 80);
  FEdTitle := MakeEdit(Self, P, 110, 16, 700);

  MakeLabel(Self, P, '作者（多人用分号分隔）', 16, 56, 170);
  FEdAuthor := MakeEdit(Self, P, 200, 52, 610);

  MakeLabel(Self, P, '语言', 16, 92, 60);
  FEdLanguage := MakeEdit(Self, P, 110, 88, 160, 'zh-CN');
  MakeLabel(Self, P, '标识符（留空自动生成 UUID）', 300, 92, 200);
  FEdIdentifier := MakeEdit(Self, P, 510, 88, 300);

  MakeLabel(Self, P, '出版社', 16, 128, 60);
  FEdPublisher := MakeEdit(Self, P, 110, 124, 700);

  MakeLabel(Self, P, '主题', 16, 164, 60);
  FEdSubject := MakeEdit(Self, P, 110, 160, 700);

  MakeLabel(Self, P, '出版日期', 16, 200, 70);
  FEdDate := MakeEdit(Self, P, 110, 196, 200, FormatDateTime('yyyy-mm-dd', Now));
  MakeLabel(Self, P, '版权', 340, 200, 60);
  FEdRights := MakeEdit(Self, P, 410, 196, 400);

  MakeLabel(Self, P, '内容简介', 16, 236, 70);
  FMemoDescription := TMemo.Create(Self);
  FMemoDescription.Parent := P;
  FMemoDescription.Left := 110;
  FMemoDescription.Top := 232;
  FMemoDescription.Width := 700;
  FMemoDescription.Height := 150;
  FMemoDescription.ScrollBars := ssVertical;
  FMemoDescription.WordWrap := True;
end;

procedure TMainForm.CreateChapterTab(APage: TTabSheet);
var
  LeftPanel, BtnPanel, EditPanel, TopPanel, InsertPanel: TPanel;
begin
  LeftPanel := TPanel.Create(Self);
  LeftPanel.Parent := APage;
  LeftPanel.Align := alLeft;
  LeftPanel.Width := 260;
  LeftPanel.BevelOuter := bvNone;
  LeftPanel.Padding.SetBounds(8, 8, 8, 8);

  FChapterList := TListBox.Create(Self);
  FChapterList.Parent := LeftPanel;
  FChapterList.Align := alClient;
  FChapterList.OnClick := ChapterListClick;

  BtnPanel := TPanel.Create(Self);
  BtnPanel.Parent := LeftPanel;
  BtnPanel.Align := alBottom;
  BtnPanel.Height := 40;
  BtnPanel.BevelOuter := bvNone;
  MakeButton(Self, BtnPanel, '添加', 2, 4, 56, 30, BtnAddChapterClick);
  MakeButton(Self, BtnPanel, '删除', 60, 4, 56, 30, BtnDeleteChapterClick);
  MakeButton(Self, BtnPanel, '上移', 120, 4, 56, 30, BtnMoveUpClick);
  MakeButton(Self, BtnPanel, '下移', 180, 4, 56, 30, BtnMoveDownClick);

  EditPanel := TPanel.Create(Self);
  EditPanel.Parent := APage;
  EditPanel.Align := alClient;
  EditPanel.BevelOuter := bvNone;
  EditPanel.Padding.SetBounds(8, 8, 8, 8);

  TopPanel := TPanel.Create(Self);
  TopPanel.Parent := EditPanel;
  TopPanel.Align := alTop;
  TopPanel.Height := 112;
  TopPanel.BevelOuter := bvNone;

  MakeLabel(Self, TopPanel, '章节标题', 0, 4, 60);
  FEdChapterTitle := MakeEdit(Self, TopPanel, 70, 0, 420);
  FEdChapterTitle.OnChange := EditorChanged;

  MakeLabel(Self, TopPanel, '层级', 500, 4, 40);
  FCboLevel := TComboBox.Create(Self);
  FCboLevel.Parent := TopPanel;
  FCboLevel.Left := 545;
  FCboLevel.Top := 0;
  FCboLevel.Width := 60;
  FCboLevel.Style := csDropDownList;
  FCboLevel.Items.Add('1');
  FCboLevel.Items.Add('2');
  FCboLevel.Items.Add('3');
  FCboLevel.Items.Add('4');
  FCboLevel.Items.Add('5');
  FCboLevel.ItemIndex := 0;
  FCboLevel.OnChange := EditorChanged;

  MakeLabel(Self, TopPanel, '父章节', 615, 4, 50);
  FCboParent := TComboBox.Create(Self);
  FCboParent.Parent := TopPanel;
  FCboParent.Left := 670;
  FCboParent.Top := 0;
  FCboParent.Width := 250;
  FCboParent.Style := csDropDownList;
  FCboParent.OnChange := EditorChanged;

  MakeLabel(Self, TopPanel, '文件名（可留空）', 0, 38, 110);
  FEdChapterFile := MakeEdit(Self, TopPanel, 120, 34, 250);
  FEdChapterFile.OnChange := EditorChanged;

  FChkInToc := MakeCheckBox(Self, TopPanel, '显示在目录中', 390, 36, 120, True);
  FChkInToc.OnClick := EditorChanged;
  FChkCoverChapter := MakeCheckBox(Self, TopPanel, '作为封面章节', 520, 36, 120, False);
  FChkCoverChapter.OnClick := EditorChanged;

  MakeLabel(Self, TopPanel, '关联 SMIL 媒体叠加（可选）', 0, 72, 180);
  FCboSmil := TComboBox.Create(Self);
  FCboSmil.Parent := TopPanel;
  FCboSmil.Left := 190;
  FCboSmil.Top := 68;
  FCboSmil.Width := 300;
  FCboSmil.Style := csDropDownList;
  FCboSmil.OnChange := EditorChanged;

  InsertPanel := TPanel.Create(Self);
  InsertPanel.Parent := EditPanel;
  InsertPanel.Align := alBottom;
  InsertPanel.Height := 40;
  InsertPanel.BevelOuter := bvNone;
  MakeLabel(Self, InsertPanel, '插入占位符 →', 0, 10, 90);
  MakeButton(Self, InsertPanel, '图片', 95, 4, 64, 30, BtnInsertImageClick);
  MakeButton(Self, InsertPanel, '音频', 165, 4, 64, 30, BtnInsertAudioClick);
  MakeButton(Self, InsertPanel, '视频', 235, 4, 64, 30, BtnInsertVideoClick);
  MakeButton(Self, InsertPanel, '章节链接', 305, 4, 84, 30, BtnInsertLinkClick);

  FMemoContent := TMemo.Create(Self);
  FMemoContent.Parent := EditPanel;
  FMemoContent.Align := alClient;
  FMemoContent.ScrollBars := ssBoth;
  FMemoContent.WordWrap := False;
  FMemoContent.Font.Name := 'Consolas';
  FMemoContent.Font.Size := 10;
  FMemoContent.OnChange := EditorChanged;
end;

procedure TMainForm.CreateResourceTab(APage: TTabSheet);
var
  Bar: TPanel;
begin
  Bar := TPanel.Create(Self);
  Bar.Parent := APage;
  Bar.Align := alTop;
  Bar.Height := 44;
  Bar.BevelOuter := bvNone;
  Bar.Padding.SetBounds(8, 6, 8, 6);

  MakeButton(Self, Bar, '添加图片', 0, 4, 82, 30, BtnAddResourceClick).Tag := Ord(akImage);
  MakeButton(Self, Bar, '添加音频', 88, 4, 82, 30, BtnAddResourceClick).Tag := Ord(akAudio);
  MakeButton(Self, Bar, '添加视频', 176, 4, 82, 30, BtnAddResourceClick).Tag := Ord(akVideo);
  MakeButton(Self, Bar, '添加 CSS', 264, 4, 82, 30, BtnAddResourceClick).Tag := Ord(akStyle);
  MakeButton(Self, Bar, '添加字体', 352, 4, 82, 30, BtnAddResourceClick).Tag := Ord(akFont);
  MakeButton(Self, Bar, '添加 SMIL', 440, 4, 86, 30, BtnAddResourceClick).Tag := Ord(akSmil);
  MakeButton(Self, Bar, '设为封面', 540, 4, 82, 30, BtnSetCoverClick);
  MakeButton(Self, Bar, '打开源文件', 628, 4, 92, 30, BtnOpenSourceClick);
  MakeButton(Self, Bar, '删除', 726, 4, 64, 30, BtnDeleteResourceClick);

  FResourceList := TListView.Create(Self);
  FResourceList.Parent := APage;
  FResourceList.Align := alClient;
  FResourceList.ViewStyle := vsReport;
  FResourceList.RowSelect := True;
  FResourceList.ReadOnly := True;
  FResourceList.GridLines := True;
  with FResourceList.Columns.Add do begin Caption := 'ID'; Width := 80; end;
  with FResourceList.Columns.Add do begin Caption := '类型'; Width := 70; end;
  with FResourceList.Columns.Add do begin Caption := '源文件'; Width := 320; end;
  with FResourceList.Columns.Add do begin Caption := '包内路径'; Width := 280; end;
  with FResourceList.Columns.Add do begin Caption := '封面'; Width := 60; end;
  FResourceList.OnClick := ResourceListClick;
end;

procedure TMainForm.CreateBuildTab(APage: TTabSheet);
var
  TopPanel: TPanel;
begin
  TopPanel := TPanel.Create(Self);
  TopPanel.Parent := APage;
  TopPanel.Align := alTop;
  TopPanel.Height := 132;
  TopPanel.BevelOuter := bvNone;
  TopPanel.Padding.SetBounds(12, 10, 12, 10);

  MakeLabel(Self, TopPanel, '输出文件', 0, 4, 60);
  FEdOutput := MakeEdit(Self, TopPanel, 70, 0, 720);
  MakeButton(Self, TopPanel, '浏览…', 800, -2, 76, 26, BtnBrowseOutputClick);

  FChkGenerateNcx := MakeCheckBox(Self, TopPanel, '兼容 EPUB 2（生成 toc.ncx）', 0, 36, 230, True);
  FChkAutoLinkStyles := MakeCheckBox(Self, TopPanel, '自动为章节链接所有 CSS', 240, 36, 230, True);

  MakeButton(Self, TopPanel, '构建 EPUB', 0, 72, 130, 36, BtnBuildClick);
  MakeButton(Self, TopPanel, '载入示例项目', 140, 72, 120, 36, BtnLoadSampleClick);
  MakeButton(Self, TopPanel, '清空全部', 270, 72, 100, 36, BtnClearClick);

  FLogMemo := TMemo.Create(Self);
  FLogMemo.Parent := APage;
  FLogMemo.Align := alClient;
  FLogMemo.ReadOnly := True;
  FLogMemo.ScrollBars := ssBoth;
  FLogMemo.Font.Name := 'Consolas';
  FLogMemo.Font.Size := 9;
end;

procedure TMainForm.SetStatus(const S: string);
begin
  FStatusBar.Panels[0].Text := S;
end;

procedure TMainForm.Log(const S: string);
begin
  FLogMemo.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
  OutputDebugString(PChar('[EpubBuilder] ' + S));
end;

{------------------------------------------------------------------------------
  章节列表与编辑器
------------------------------------------------------------------------------}

function TMainForm.CurrentChapter: TGuiChapter;
var
  I: Integer;
begin
  I := FChapterList.ItemIndex;
  if (I >= 0) and (I < FChapters.Count) then
    Result := FChapters[I]
  else
    Result := nil;
end;

function TMainForm.CurrentResource: TGuiResource;
begin
  if FResourceList.Selected = nil then
    Exit(nil);
  Result := TGuiResource(FResourceList.Selected.Data);
end;

procedure TMainForm.RefreshChapterList;
var
  I: Integer;
  Old: Integer;
begin
  Old := FChapterList.ItemIndex;
  FChapterList.Items.BeginUpdate;
  try
    FChapterList.Items.Clear;
    for I := 0 to FChapters.Count - 1 do
      FChapterList.Items.AddObject(StringOfChar(' ', (FChapters[I].Level - 1) * 2) +
        FChapters[I].Title, FChapters[I]);
    if (Old >= 0) and (Old < FChapterList.Items.Count) then
      FChapterList.ItemIndex := Old;
  finally
    FChapterList.Items.EndUpdate;
  end;
  RefreshParentCombo;
end;

procedure TMainForm.RefreshParentCombo;
var
  I, Keep: Integer;
  C: TGuiChapter;
begin
  C := CurrentChapter;
  Keep := FCboParent.ItemIndex;
  FCboParent.Items.BeginUpdate;
  try
    FCboParent.Items.Clear;
    FCboParent.Items.AddObject('（无 - 顶层）', nil);
    for I := 0 to FChapters.Count - 1 do
      if FChapters[I] <> C then
        FCboParent.Items.AddObject(FChapters[I].Title, FChapters[I]);
    FCboParent.ItemIndex := 0;
    if C <> nil then
      for I := 0 to FCboParent.Items.Count - 1 do
        if FCboParent.Items.Objects[I] = Pointer(C.Parent) then
          FCboParent.ItemIndex := I;
  finally
    FCboParent.Items.EndUpdate;
  end;
end;

procedure TMainForm.RefreshSmilCombo;
var
  I: Integer;
  R: TGuiResource;
  C: TGuiChapter;
begin
  C := CurrentChapter;
  FCboSmil.Items.Clear;
  FCboSmil.Items.AddObject('（无）', nil);
  for I := 0 to FResources.Count - 1 do
  begin
    R := FResources[I];
    if R.Kind = akSmil then
      FCboSmil.Items.AddObject(R.Id + ' - ' + ExtractFileName(R.SourceFile), R);
  end;
  FCboSmil.ItemIndex := 0;
  if C <> nil then
    for I := 0 to FCboSmil.Items.Count - 1 do
      if (FCboSmil.Items.Objects[I] <> nil) and
         SameText(TGuiResource(FCboSmil.Items.Objects[I]).Id, C.SmilResourceId) then
        FCboSmil.ItemIndex := I;
end;

procedure TMainForm.LoadChapterToEditor;
var
  C: TGuiChapter;
  I: Integer;
begin
  C := CurrentChapter;
  FLoading := True;
  try
    if C = nil then
    begin
      FEdChapterTitle.Text := '';
      FEdChapterFile.Text := '';
      FEdChapterTitle.Enabled := False;
      FEdChapterFile.Enabled := False;
      FMemoContent.Enabled := False;
      FCboLevel.Enabled := False;
      FCboParent.Enabled := False;
      FCboSmil.Enabled := False;
      FChkInToc.Enabled := False;
      FChkCoverChapter.Enabled := False;
      FMemoContent.Text := '';
      Exit;
    end;

    FEdChapterTitle.Enabled := True;
    FEdChapterFile.Enabled := True;
    FMemoContent.Enabled := True;
    FCboLevel.Enabled := True;
    FCboParent.Enabled := True;
    FCboSmil.Enabled := True;
    FChkInToc.Enabled := True;
    FChkCoverChapter.Enabled := True;

    FEdChapterTitle.Text := C.Title;
    FEdChapterFile.Text := C.FileName;
    FMemoContent.Text := C.Content;
    if (C.Level >= 1) and (C.Level <= FCboLevel.Items.Count) then
      FCboLevel.ItemIndex := C.Level - 1;
    FChkInToc.Checked := C.InToc;
    FChkCoverChapter.Checked := C.IsCover;
    RefreshParentCombo;
    RefreshSmilCombo;
    I := 0;
    for I := 0 to FCboParent.Items.Count - 1 do
      if FCboParent.Items.Objects[I] = Pointer(C.Parent) then
      begin
        FCboParent.ItemIndex := I;
        Break;
      end;
  finally
    FLoading := False;
  end;
end;

procedure TMainForm.SaveEditorToChapter(Sender: TObject);
var
  C: TGuiChapter;
  I: Integer;
  R: TGuiResource;
begin
  if FLoading then
    Exit;
  C := CurrentChapter;
  if C = nil then
    Exit;

  C.Title := FEdChapterTitle.Text;
  C.FileName := FEdChapterFile.Text;
  C.Content := FMemoContent.Text;
  if FCboLevel.ItemIndex >= 0 then
    C.Level := FCboLevel.ItemIndex + 1;
  C.InToc := FChkInToc.Checked;
  C.IsCover := FChkCoverChapter.Checked;
  I := FCboParent.ItemIndex;
  if I >= 0 then
    C.Parent := TGuiChapter(FCboParent.Items.Objects[I]);
  I := FCboSmil.ItemIndex;
  if (I >= 0) and (FCboSmil.Items.Objects[I] <> nil) then
  begin
    R := TGuiResource(FCboSmil.Items.Objects[I]);
    C.SmilResourceId := R.Id;
  end
  else
    C.SmilResourceId := '';

  I := FChapterList.ItemIndex;
  if I >= 0 then
    FChapterList.Items[I] := StringOfChar(' ', (C.Level - 1) * 2) + C.Title;
end;

procedure TMainForm.EditorChanged(Sender: TObject);
begin
  SaveEditorToChapter(Sender);
end;

procedure TMainForm.ChapterListClick(Sender: TObject);
begin
  LoadChapterToEditor;
end;

procedure TMainForm.BtnAddChapterClick(Sender: TObject);
var
  C: TGuiChapter;
begin
  C := TGuiChapter.Create(NewId('C'));
  FChapters.Add(C);
  RefreshChapterList;
  FChapterList.ItemIndex := FChapters.Count - 1;
  LoadChapterToEditor;
  FEdChapterTitle.SetFocus;
  SetStatus('已添加章节 ' + C.Id);
end;

procedure TMainForm.BtnDeleteChapterClick(Sender: TObject);
var
  C: TGuiChapter;
  I: Integer;
begin
  C := CurrentChapter;
  if C = nil then
    Exit;
  if MessageDlg('确定删除章节「' + C.Title + '」？', mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then
    Exit;

  for I := 0 to FChapters.Count - 1 do
    if FChapters[I].Parent = C then
      FChapters[I].Parent := C.Parent;
  FChapters.Remove(C);
  C.Free;
  RefreshChapterList;
  if FChapterList.Items.Count > 0 then
    FChapterList.ItemIndex := 0;
  LoadChapterToEditor;
  SetStatus('已删除章节');
end;

procedure TMainForm.BtnMoveUpClick(Sender: TObject);
var
  I: Integer;
begin
  I := FChapterList.ItemIndex;
  if I <= 0 then
    Exit;
  FChapters.Exchange(I, I - 1);
  RefreshChapterList;
  FChapterList.ItemIndex := I - 1;
  LoadChapterToEditor;
end;

procedure TMainForm.BtnMoveDownClick(Sender: TObject);
var
  I: Integer;
begin
  I := FChapterList.ItemIndex;
  if (I < 0) or (I >= FChapters.Count - 1) then
    Exit;
  FChapters.Exchange(I, I + 1);
  RefreshChapterList;
  FChapterList.ItemIndex := I + 1;
  LoadChapterToEditor;
end;

{------------------------------------------------------------------------------
  占位符插入
------------------------------------------------------------------------------}

function TMainForm.SelectFromList(const ACaption: string; const AItems: TStrings;
  out AIndex: Integer): Boolean;
var
  Dlg: TForm;
  LB: TListBox;
  BtnOk, BtnCancel: TButton;
begin
  Result := False;
  AIndex := -1;
  Dlg := TForm.Create(nil);
  try
    Dlg.Caption := ACaption;
    Dlg.Width := 460;
    Dlg.Height := 320;
    Dlg.Position := poOwnerFormCenter;
    Dlg.BorderStyle := bsDialog;

    LB := TListBox.Create(Dlg);
    LB.Parent := Dlg;
    LB.Align := alClient;
    LB.Items.Assign(AItems);
    if LB.Items.Count > 0 then
      LB.ItemIndex := 0;

    BtnOk := TButton.Create(Dlg);
    BtnOk.Parent := Dlg;
    BtnOk.Caption := '确定';
    BtnOk.ModalResult := mrOk;
    BtnOk.Left := Dlg.Width - 166;
    BtnOk.Top := Dlg.Height - 42;
    BtnOk.Width := 74;
    BtnOk.Height := 30;
    BtnOk.Default := True;

    BtnCancel := TButton.Create(Dlg);
    BtnCancel.Parent := Dlg;
    BtnCancel.Caption := '取消';
    BtnCancel.ModalResult := mrCancel;
    BtnCancel.Left := Dlg.Width - 86;
    BtnCancel.Top := Dlg.Height - 42;
    BtnCancel.Width := 74;
    BtnCancel.Height := 30;
    BtnCancel.Cancel := True;

    if (Dlg.ShowModal = mrOk) and (LB.ItemIndex >= 0) then
    begin
      AIndex := LB.ItemIndex;
      Result := True;
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TMainForm.InsertToken(const AToken: string);
var
  P: Integer;
begin
  P := FMemoContent.SelStart;
  FMemoContent.Text := Copy(FMemoContent.Text, 1, P) + AToken +
    Copy(FMemoContent.Text, P + 1, MaxInt);
  FMemoContent.SelStart := P + Length(AToken);
  FMemoContent.Perform(EM_SETSEL, FMemoContent.SelStart, FMemoContent.SelStart);
  SaveEditorToChapter(nil);
end;

procedure TMainForm.BtnInsertAudioClick(Sender: TObject);
var
  L: TStringList;
  I, Idx: Integer;
begin
  L := TStringList.Create;
  try
    for I := 0 to FResources.Count - 1 do
      if FResources[I].Kind = akAudio then
        L.Add(FResources[I].Id + ' - ' + ExtractFileName(FResources[I].SourceFile));
    if L.Count = 0 then
    begin
      ShowMessage('请先添加音频资源。');
      Exit;
    end;
    if SelectFromList('选择要插入的音频', L, Idx) then
    begin
      I := 0;
      Idx := 0;
      // 找到对应的资源 ID
      for I := 0 to FResources.Count - 1 do
        if (FResources[I].Kind = akAudio) and
           (Pos(FResources[I].Id + ' - ', L[Idx]) = 1) then
        begin
          InsertToken('{{audio:' + FResources[I].Id + '}}');
          Break;
        end;
    end;
  finally
    L.Free;
  end;
end;

procedure TMainForm.BtnInsertVideoClick(Sender: TObject);
var
  L: TStringList;
  I, Idx: Integer;
begin
  L := TStringList.Create;
  try
    for I := 0 to FResources.Count - 1 do
      if FResources[I].Kind = akVideo then
        L.Add(FResources[I].Id + ' - ' + ExtractFileName(FResources[I].SourceFile));
    if L.Count = 0 then
    begin
      ShowMessage('请先添加视频资源。');
      Exit;
    end;
    if SelectFromList('选择要插入的视频', L, Idx) then
      for I := 0 to FResources.Count - 1 do
        if (FResources[I].Kind = akVideo) and
           (Pos(FResources[I].Id + ' - ', L[Idx]) = 1) then
        begin
          InsertToken('{{video:' + FResources[I].Id + '}}');
          Break;
        end;
  finally
    L.Free;
  end;
end;

procedure TMainForm.BtnInsertImageClick(Sender: TObject);
var
  L: TStringList;
  I, Idx: Integer;
begin
  L := TStringList.Create;
  try
    for I := 0 to FResources.Count - 1 do
      if FResources[I].Kind = akImage then
        L.Add(FResources[I].Id + ' - ' + ExtractFileName(FResources[I].SourceFile));
    if L.Count = 0 then
    begin
      ShowMessage('请先添加图片资源。');
      Exit;
    end;
    if SelectFromList('选择要插入的图片', L, Idx) then
      for I := 0 to FResources.Count - 1 do
        if (FResources[I].Kind = akImage) and
           (Pos(FResources[I].Id + ' - ', L[Idx]) = 1) then
        begin
          InsertToken('{{image:' + FResources[I].Id + '}}');
          Break;
        end;
  finally
    L.Free;
  end;
end;

procedure TMainForm.BtnInsertLinkClick(Sender: TObject);
var
  L: TStringList;
  I, Idx: Integer;
begin
  L := TStringList.Create;
  try
    for I := 0 to FResources.Count - 1 do
      L.Add('');
    L.Clear;
    for I := 0 to FChapters.Count - 1 do
      L.Add(FChapters[I].Id + ' - ' + FChapters[I].Title);
    if L.Count = 0 then
    begin
      ShowMessage('请先添加章节。');
      Exit;
    end;
    if SelectFromList('选择要链接的章节', L, Idx) then
      for I := 0 to FChapters.Count - 1 do
        if Pos(FChapters[I].Id + ' - ', L[Idx]) = 1 then
        begin
          InsertToken('{{link:' + FChapters[I].Id + '}}');
          Break;
        end;
  finally
    L.Free;
  end;
end;

{------------------------------------------------------------------------------
  资源管理
------------------------------------------------------------------------------}

procedure TMainForm.RefreshResourceList;
var
  I: Integer;
  R: TGuiResource;
  Item: TListItem;
begin
  FResourceList.Items.BeginUpdate;
  try
    FResourceList.Items.Clear;
    for I := 0 to FResources.Count - 1 do
    begin
      R := FResources[I];
      Item := FResourceList.Items.Add;
      Item.Caption := R.Id;
      Item.SubItems.Add(R.KindName);
      Item.SubItems.Add(ExtractFileName(R.SourceFile));
      Item.SubItems.Add(R.ArchiveName);
      if R.IsCover then
        Item.SubItems.Add('是')
      else
        Item.SubItems.Add('');
      Item.Data := R;
    end;
  finally
    FResourceList.Items.EndUpdate;
  end;
  RefreshSmilCombo;
end;

procedure TMainForm.BtnAddResourceClick(Sender: TObject);
var
  Kind: TEpubAssetKind;
  Dlg: TOpenDialog;
  R: TGuiResource;
  Ext: string;
begin
  Kind := TEpubAssetKind(TButton(Sender).Tag);
  Dlg := TOpenDialog.Create(Self);
  try
    case Kind of
      akImage: Dlg.Filter := '图片|*.jpg;*.jpeg;*.png;*.gif;*.svg;*.webp;*.bmp';
      akAudio: Dlg.Filter := '音频|*.mp3;*.m4a;*.aac;*.ogg;*.oga;*.opus;*.wav;*.flac';
      akVideo: Dlg.Filter := '视频|*.mp4;*.m4v;*.webm;*.ogv;*.mkv;*.avi';
      akStyle: Dlg.Filter := '样式表|*.css';
      akFont:  Dlg.Filter := '字体|*.ttf;*.otf;*.woff;*.woff2;*.eot';
      akSmil:  Dlg.Filter := 'SMIL|*.smil;*.xml';
    else
      Dlg.Filter := '所有文件|*.*';
    end;
    Dlg.FilterIndex := 1;
    if not Dlg.Execute then
      Exit;

    R := TGuiResource.Create(NewId('R'));
    R.Kind := Kind;
    R.SourceFile := Dlg.FileName;
    Ext := LowerCase(ExtractFileExt(Dlg.FileName));
    Delete(Ext, 1, 1);
    R.ArchiveName := ChangeFileExt(ExtractFileName(Dlg.FileName), '') + '.' + Ext;
    if (Kind = akStyle) and (Ext <> 'css') then
      R.ArchiveName := ChangeFileExt(R.ArchiveName, '.css');
    R.MimeType := TEpubGenerator.GuessMimeType(Dlg.FileName);
    FResources.Add(R);
    RefreshResourceList;
    Log('添加资源 ' + R.Id + ' [' + R.KindName + '] ' + ExtractFileName(R.SourceFile));
    SetStatus('已添加资源 ' + R.Id);
  finally
    Dlg.Free;
  end;
end;

procedure TMainForm.BtnSetCoverClick(Sender: TObject);
var
  R: TGuiResource;
  I: Integer;
begin
  R := CurrentResource;
  if R = nil then
    Exit;
  if R.Kind <> akImage then
  begin
    ShowMessage('只有图片资源可以设为封面。');
    Exit;
  end;
  for I := 0 to FResources.Count - 1 do
    FResources[I].IsCover := False;
  R.IsCover := True;
  RefreshResourceList;
  SetStatus('封面已设为 ' + R.Id);
end;

procedure TMainForm.BtnDeleteResourceClick(Sender: TObject);
var
  R: TGuiResource;
  I: Integer;
begin
  R := CurrentResource;
  if R = nil then
    Exit;
  if MessageDlg('确定删除资源 ' + R.Id + '？', mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then
    Exit;
  for I := 0 to FChapters.Count - 1 do
    if SameText(FChapters[I].SmilResourceId, R.Id) then
      FChapters[I].SmilResourceId := '';
  FResources.Remove(R);
  R.Free;
  RefreshResourceList;
  LoadChapterToEditor;
end;

procedure TMainForm.BtnOpenSourceClick(Sender: TObject);
var
  R: TGuiResource;
begin
  R := CurrentResource;
  if (R <> nil) and TFile.Exists(R.SourceFile) then
    ShellExecute(0, 'open', PChar(R.SourceFile), nil, nil, SW_SHOWNORMAL);
end;

procedure TMainForm.ResourceListClick(Sender: TObject);
begin
  // 仅用于更新选择状态
end;

{------------------------------------------------------------------------------
  构建
------------------------------------------------------------------------------}

procedure TMainForm.BtnBrowseOutputClick(Sender: TObject);
var
  Dlg: TSaveDialog;
begin
  Dlg := TSaveDialog.Create(Self);
  try
    Dlg.Filter := 'EPUB 文件|*.epub';
    Dlg.DefaultExt := 'epub';
    Dlg.FileName := FEdOutput.Text;
    if Dlg.Execute then
      FEdOutput.Text := Dlg.FileName;
  finally
    Dlg.Free;
  end;
end;

function TMainForm.BuildEpub(const AOutputFile: string): Boolean;
var
  G: TEpubGenerator;
  I, J: Integer;
  Gc: TGuiChapter;
  Gr: TGuiResource;
  Genc, GenParent: TEpubChapter;
  A: TEpubAsset;
  ChapterMap: TDictionary<TGuiChapter, TEpubChapter>;
  AssetMap: TDictionary<TGuiResource, TEpubAsset>;
  Authors: TArray<string>;
  Author: string;
  OutPath: string;
begin
  Result := False;
  if FChapters.Count = 0 then
  begin
    Log('错误：至少需要添加一个章节。');
    Exit;
  end;
  if Trim(AOutputFile) = '' then
  begin
    Log('错误：请指定输出文件。');
    Exit;
  end;

  OutPath := TPath.GetFullPath(AOutputFile);
  ChapterMap := TDictionary<TGuiChapter, TEpubChapter>.Create;
  AssetMap := TDictionary<TGuiResource, TEpubAsset>.Create;
  G := TEpubGenerator.Create;
  try
    Log('开始构建：' + OutPath);

    { 元数据 }
    G.Metadata.Title := FEdTitle.Text;
    G.Metadata.AddAuthor(''); // 占位，随后清空
    G.Metadata.ClearAuthors;
    Authors := StringReplace(FEdAuthor.Text, '；', ';', [rfReplaceAll])
      .Split([';', ','], TStringSplitOptions.ExcludeEmpty);
    for Author in Authors do
      G.Metadata.AddAuthor(Trim(Author));
    G.Metadata.Language := Trim(FEdLanguage.Text);
    if Trim(FEdIdentifier.Text) <> '' then
      G.Metadata.Identifier := Trim(FEdIdentifier.Text);
    G.Metadata.Publisher := FEdPublisher.Text;
    G.Metadata.Description := FMemoDescription.Text;
    G.Metadata.Subject := FEdSubject.Text;
    G.Metadata.Date := FEdDate.Text;
    G.Metadata.Rights := FEdRights.Text;
    G.Metadata.ModifiedUTC := TTimeZone.Local.ToUniversalTime(Now);
    G.GenerateNCX := FChkGenerateNcx.Checked;
    G.AutoLinkStyles := FChkAutoLinkStyles.Checked;
    Log('元数据已写入，章节数 ' + FChapters.Count.ToString +
      '，资源数 ' + FResources.Count.ToString);

    { 资源 }
    for I := 0 to FResources.Count - 1 do
    begin
      Gr := FResources[I];
      if not TFile.Exists(Gr.SourceFile) then
      begin
        Log('错误：资源文件不存在 ' + Gr.SourceFile);
        Exit;
      end;
      case Gr.Kind of
        akImage:
          if Gr.IsCover then
            A := G.AddCoverImage(Gr.SourceFile, Gr.ArchiveName)
          else
            A := G.AddImage(Gr.SourceFile, Gr.ArchiveName, Gr.MimeType);
        akAudio: A := G.AddAudio(Gr.SourceFile, Gr.ArchiveName, Gr.MimeType);
        akVideo: A := G.AddVideo(Gr.SourceFile, Gr.ArchiveName, Gr.MimeType);
        akStyle: A := G.AddStyle(Gr.SourceFile, Gr.ArchiveName);
        akFont:  A := G.AddFont(Gr.SourceFile, Gr.ArchiveName);
        akSmil:  A := G.AddAsset(Gr.SourceFile, Gr.ArchiveName,
                    'application/smil+xml', akSmil);
      else
        A := G.AddAsset(Gr.SourceFile, Gr.ArchiveName, Gr.MimeType, akOther);
      end;
      A.Id := Gr.Id;  // 使用界面稳定 ID，使占位符可解析
      A.Alt := ChangeFileExt(ExtractFileName(Gr.SourceFile), '');
      AssetMap.Add(Gr, A);
      Log('  资源 ' + Gr.Id + ' [' + Gr.KindName + '] -> ' + A.Href);
    end;

    { 章节 - 第一遍 }
    for I := 0 to FChapters.Count - 1 do
    begin
      Gc := FChapters[I];
      Genc := G.AddChapter(Gc.Title, Gc.Content, Gc.Level, '', Gc.FileName);
      Genc.Id := Gc.Id;  // 稳定 ID，供 {{link:...}} 使用
      Genc.InToc := Gc.InToc;
      if Gc.IsCover then
        G.SetCoverChapter(Genc);
      ChapterMap.Add(Gc, Genc);
    end;

    { 章节 - 第二遍：父子层级与 SMIL }
    for I := 0 to FChapters.Count - 1 do
    begin
      Gc := FChapters[I];
      Genc := ChapterMap[Gc];
      if (Gc.Parent <> nil) and ChapterMap.TryGetValue(Gc.Parent, GenParent) then
        Genc.ParentId := GenParent.Id;
      if Gc.SmilResourceId <> '' then
        for J := 0 to FResources.Count - 1 do
          if SameText(FResources[J].Id, Gc.SmilResourceId) and
             AssetMap.TryGetValue(FResources[J], A) then
          begin
            Genc.MediaOverlayId := A.Id;
            Break;
          end;
    end;

    { 输出 }
    G.SaveToFile(OutPath);
    if not TZipFile.IsValid(OutPath) then
    begin
      Log('错误：生成的文件不是有效的 ZIP/EPUB 容器。');
      Exit;
    end;

    Log('构建完成：' + OutPath + '（' +
      TFile.GetSize(OutPath).ToString + ' 字节）');
    SetStatus('构建成功');
    Result := True;
  except
    on E: Exception do
      Log('构建失败：' + E.Message);
  end;
  ChapterMap.Free;
  AssetMap.Free;
  G.Free;
end;

procedure TMainForm.BtnBuildClick(Sender: TObject);
var
  OutFile: string;
begin
  FLogMemo.Lines.Clear;
  OutFile := Trim(FEdOutput.Text);
  if OutFile = '' then
  begin
    OutFile := TPath.Combine(TPath.GetDocumentsPath, 'SampleBook.epub');
    FEdOutput.Text := OutFile;
  end;
  if BuildEpub(OutFile) then
    MessageDlg('EPUB 构建成功！' + sLineBreak + OutFile,
      mtInformation, [mbOK], 0)
  else
    MessageDlg('构建失败，请查看日志。', mtError, [mbOK], 0);
end;

{------------------------------------------------------------------------------
  示例 / 清空 / 自检
------------------------------------------------------------------------------}

procedure TMainForm.LoadSample(ASilent: Boolean);
var
  AppDir, AssetsDir: string;
  R: TGuiResource;
  C1, C2, C3, C4: TGuiChapter;
begin
  FChapters.Clear;
  FResources.Clear;
  FIdCounter := 0;

  FEdTitle.Text := 'EPUB 音视频生成器演示';
  FEdAuthor.Text := 'Delphi 12.2;System.Zip';
  FEdLanguage.Text := 'zh-CN';
  FEdIdentifier.Text := '';
  FEdPublisher.Text := 'EpubBuilder GUI';
  FEdSubject.Text := 'EPUB 3.0，音视频';
  FEdDate.Text := FormatDateTime('yyyy-mm-dd', Now);
  FEdRights.Text := '测试演示';
  FMemoDescription.Text := '由可视化构建器生成的示例，包含音频、视频、图片与 SMIL 媒体叠加。';

  AppDir := ExtractFilePath(ParamStr(0));
  AssetsDir := TPath.GetFullPath(TPath.Combine(AppDir, '..\TestAssets'));
  if TDirectory.Exists(AssetsDir) then
  begin
    if TFile.Exists(TPath.Combine(AssetsDir, 'cover.png')) then
    begin
      R := TGuiResource.Create(NewId('R'));
      R.Kind := akImage;
      R.SourceFile := TPath.Combine(AssetsDir, 'cover.png');
      R.ArchiveName := 'cover.png';
      R.MimeType := 'image/png';
      R.IsCover := True;
      FResources.Add(R);
    end;
    if TFile.Exists(TPath.Combine(AssetsDir, 'sample.mp3')) then
    begin
      R := TGuiResource.Create(NewId('R'));
      R.Kind := akAudio;
      R.SourceFile := TPath.Combine(AssetsDir, 'sample.mp3');
      R.ArchiveName := 'narration.mp3';
      R.MimeType := 'audio/mpeg';
      FResources.Add(R);
    end;
    if TFile.Exists(TPath.Combine(AssetsDir, 'sample.mp4')) then
    begin
      R := TGuiResource.Create(NewId('R'));
      R.Kind := akVideo;
      R.SourceFile := TPath.Combine(AssetsDir, 'sample.mp4');
      R.ArchiveName := 'demo.mp4';
      R.MimeType := 'video/mp4';
      FResources.Add(R);
    end;
  end;

  C1 := TGuiChapter.Create(NewId('C'));
  C1.Title := '封面';
  C1.FileName := 'cover.xhtml';
  C1.InToc := False;
  C1.IsCover := True;
  C1.Content := '<div style="text-align:center">' +
    '{{image:R001}}' + sLineBreak +
    '<h1>EPUB 音视频生成器演示</h1>' +
    '<p>Delphi 12.2 + System.Zip</p></div>';
  FChapters.Add(C1);

  C2 := TGuiChapter.Create(NewId('C'));
  C2.Title := '第一章 简介';
  C2.FileName := 'chapter001.xhtml';
  C2.Content := '<h1>第一章 简介</h1>' + sLineBreak +
    '<p>本书由可视化构建器生成，支持音视频与多级目录。</p>' + sLineBreak +
    '<p>跳转到下一章：{{link:C006}}</p>';
  FChapters.Add(C2);

  C3 := TGuiChapter.Create(NewId('C'));
  C3.Title := '第二章 音视频';
  C3.FileName := 'chapter002.xhtml';
  C3.Content := '<h1>第二章 音视频</h1>' + sLineBreak +
    '<p id="intro">下面是一段 MP3 音频。</p>' + sLineBreak +
    '{{audio:R002}}' + sLineBreak +
    '<p>下面是一段 MP4 视频。</p>' + sLineBreak +
    '{{video:R003}}';
  FChapters.Add(C3);

  C4 := TGuiChapter.Create(NewId('C'));
  C4.Title := '2.1 音频细节';
  C4.FileName := 'chapter002_1.xhtml';
  C4.Level := 2;
  C4.Parent := C3;
  C4.Content := '<h2>2.1 音频细节</h2><p>二级目录示例。</p>';
  FChapters.Add(C4);

  RefreshChapterList;
  RefreshResourceList;
  FChapterList.ItemIndex := 0;
  LoadChapterToEditor;

  FEdOutput.Text := TPath.Combine(TPath.GetFullPath(TPath.Combine(AppDir, '..\Output')),
    'SampleBookGUI.epub');

  if not ASilent then
  begin
    Log('已载入示例项目：' + FChapters.Count.ToString + ' 个章节，' +
      FResources.Count.ToString + ' 个资源。');
    SetStatus('示例项目已载入');
  end;
end;

procedure TMainForm.BtnLoadSampleClick(Sender: TObject);
begin
  LoadSample(False);
end;

procedure TMainForm.BtnClearClick(Sender: TObject);
begin
  if MessageDlg('确定清空当前项目？', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  FChapters.Clear;
  FResources.Clear;
  FIdCounter := 0;
  RefreshChapterList;
  RefreshResourceList;
  LoadChapterToEditor;
  FLogMemo.Lines.Clear;
  SetStatus('已清空');
end;

class procedure TMainForm.RunSelfTest;
var
  F: TMainForm;
  LogPath, OutPath: string;
  Lines: TStringList;
begin
  F := TMainForm.Create(nil);
  Lines := TStringList.Create;
  try
    OutPath := TPath.Combine(TPath.GetTempPath, 'EpuBuilderGuiSelfTest.epub');
    LogPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'selftest.log');
    if F.BuildEpub(OutPath) then
      Lines.Add('SELFTEST RESULT: PASS')
    else
      Lines.Add('SELFTEST RESULT: FAIL');
    Lines.Add('OUTPUT: ' + OutPath);
    Lines.AddStrings(F.FLogMemo.Lines);
    Lines.SaveToFile(LogPath, TEncoding.UTF8);
  finally
    Lines.Free;
    F.Free;
  end;
end;

end.
