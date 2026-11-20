unit MainForm;

{==============================================================================
  MainForm.pas —— EPUB 可视化构建器主窗体

  纯代码创建全部 VCL 控件（不依赖 DFM），复用 EpubGenerator.pas 完成打包。
  功能：元数据编辑 / 章节层级管理 / 音视频图片样式字体资源 / SMIL 关联 /
        占位符插入 / 一键构建与日志 / 示例项目 / 无人值守自检。
  章节内容编辑器采用工作区自带的 SynEdit 控件，应用其 HTML 高亮样式，
        并在输入 { 时通过 TSynCompletionProposal 智能提示可插入的资源。
==============================================================================}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  System.StrUtils,
  System.DateUtils,
  System.NetEncoding,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ComCtrls,
  Vcl.Dialogs,
  Vcl.ExtCtrls,
  Vcl.MPlayer,
  Vcl.Graphics,
  Vcl.Imaging.pngimage,
  Vcl.Imaging.jpeg,
  Vcl.Imaging.GIFImg,
  Winapi.Messages,
  Winapi.Windows,
  Winapi.ShellAPI,
  System.Zip,
  System.UITypes,
  System.IniFiles,
  SynEdit,
  SynEditHighlighter,
  SynHighlighterHtml,
  SynCompletionProposal,
  EpubPlaceholderSyn,
  Langji.Wke.lib,
  Langji.Wke.types,
  Langji.Wke.Webbrowser,
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

  { 图片预览面板相对补全候选列表框的停靠位置 }
  TPreviewDock = (pdAuto, pdLeft, pdTop, pdRight, pdBottom);

  { 占位符样式设置对话框：按类型分别设置前景色 / 背景色 / 字型样式，
    结果写入 TSynEpubPlaceholderSyn 的 TSynHighlighterAttributes 并持久化到 ini。
    使用 CreateNew 创建，避免无 DFM 时 TForm.Create 触发资源加载异常。 }
  TPlaceholderStyleDialog = class(TForm)
  private
    FHighlighter: TSynEpubPlaceholderSyn;
    FCboKind: TComboBox;
    FBtnFore, FBtnBack: TButton;
    FChkBold, FChkItalic, FChkUnderline, FChkStrike: TCheckBox;
    FPreview: TLabel;
    FFore, FBack: array[TEpubPlaceholderKind] of TColor;
    FStyles: array[TEpubPlaceholderKind] of TFontStyles;
    FCurrent: TEpubPlaceholderKind;
    procedure LoadFromHighlighter;
    procedure ApplyToHighlighter;
    procedure ShowKind(AKind: TEpubPlaceholderKind);
    procedure UpdatePreview;
    procedure CboKindChange(Sender: TObject);
    procedure BtnForeClick(Sender: TObject);
    procedure BtnBackClick(Sender: TObject);
    procedure ChkClick(Sender: TObject);
    procedure BtnResetClick(Sender: TObject);
  public
    procedure Init(AHighlighter: TSynEpubPlaceholderSyn);
  end;

  TViewSourceForm = class(TForm)
  private
    FSourceEditor: TSynEdit;
    FSourceHighlighter: TSynHTMLSyn;
    FClickedPoint: TPoint;
    FMouseDownPt: TPoint;
    { 源码格式化排版按钮（再次点击可恢复原始源码） }
    FFormatButton: TButton;
    FStatusLabel: TLabel;
    FOriginalSource: string;
    FIsFormatted: Boolean;
    procedure BtnCopyClick(Sender: TObject);
    procedure BtnCloseClick(Sender: TObject);
    procedure BtnFormatClick(Sender: TObject);
    procedure UpdateFormatStatus(const S: string);
    { 点击 HTML 标签：把该标签整体设为选区以浅灰背景高亮 }
    procedure SourceEditorMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure SourceEditorMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure WMSetTagSelection(var Message: TMessage); message WM_APP + $11;
    procedure SelectTagAt(const APoint: TPoint);
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetSource(const ASource: string);
    function FormatSource: Boolean;
    function RestoreSource: Boolean;
    function IsFormatted: Boolean;
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
    FCboLanguage: TComboBox;
    FEdIdentifier: TEdit;
    FEdPublisher: TEdit;
    FEdSubject: TEdit;
    FEdDate: TDateTimePicker;   { 出版日期：Delphi 自带日历下拉控件 }
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
    FSynEditor: TSynEdit;
    FHtmlHighlighter: TSynHTMLSyn;
    { 章节编辑器实际高亮器：TSynHTMLSyn 的派生类，可为占位符单独着色。
      FHtmlHighlighter 与它指向同一实例，保持既有 TSynHTMLSyn 接口兼容。 }
    FPlaceholderHighlighter: TSynEpubPlaceholderSyn;
    { 章节编辑器点击成对 HTML 标签整体高亮（与查看源代码窗体行为一致） }
    FEditorMouseDownPt: TPoint;
    FEditorClickedPoint: TPoint;
    FResourceProposal: TSynCompletionProposal;
    { 智能提示候选项（物理索引）→ 图片资源源文件路径（非图片项为空串） }
    FProposalItemFiles: TArray<string>;
    { 图片预览面板：章节编辑页内的普通 TPanel，选中图片候选时实时显示 }
    FImagePreviewPanel: TPanel;
    FPreviewImage: TImage;
    FPreviewImageLabel: TLabel;
    { 预览面板停靠偏好（自动/左/上/右/下），可运行时切换并持久化 }
    FPreviewDock: TPreviewDock;
    FCboPreviewDock: TComboBox;

    { 资源页 }
    FResourceList: TListView;

    { 预览页：基于 Wke（MiniBlink / Chromium 内核）的浏览器 }
    FPreviewBrowser: TWkeWebBrowser;
    { 最近一次加载到 FPreviewBrowser 的 HTML，用作源代码查看的后备 }
    FLastPreviewHtml: string;
    { 含非 ASCII 路径的媒体文件预览副本（临时 ASCII 路径，刷新时清理） }
    FPreviewTempFiles: TArray<string>;
    FPreviewCopyIndex: Integer;
    { 媒体预览栏：Wke.dll 无 HTML5 媒体后端，使用系统解码器播放 }
    FMediaPanel: TPanel;
    FMediaCombo: TComboBox;
    FMediaPlayer: TMediaPlayer;
    { 资源 ID → 可用于本地播放的文件路径（可能为 ASCII 临时副本） }
    FMediaPreviewFiles: TDictionary<string, string>;

    { 构建页 }
    FEdOutput: TEdit;
    FChkGenerateNcx: TCheckBox;
    FChkAutoLinkStyles: TCheckBox;
    FLogMemo: TMemo;

    procedure BuildUi;
    procedure ConfigureHtmlHighlighter;
    procedure CreateMetaTab(APage: TTabSheet);
    procedure CreateChapterTab(APage: TTabSheet);
    procedure CreateResourceTab(APage: TTabSheet);
    procedure CreatePreviewTab(APage: TTabSheet);
    procedure CreateBuildTab(APage: TTabSheet);

    { 编辑器字体（默认宋体 12，可自定义，ini 持久化） }
    procedure LoadEditorFont;
    procedure SaveEditorFont;
    procedure BtnFontSettingsClick(Sender: TObject);
    { 自定义占位符样式（基于 TSynCustomHighlighter 的各类 TSynHighlighterAttributes） }
    procedure BtnPlaceholderStyleClick(Sender: TObject);
    { 章节内容 HTML 格式化排版（与查看源代码共用 FormatHtmlSource） }
    procedure BtnFormatChapterClick(Sender: TObject);
    { 章节编辑器：点击 <div> 等成对标签时整体浅灰高亮 }
    procedure ChapterEditorMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ChapterEditorMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure WMChapterTagSelection(var Message: TMessage); message WM_APP + $12;
    procedure SelectTagInChapterEditor(const APoint: TPoint);

    { HTML 预览 }
    procedure RefreshPreview;
    function BuildPreviewHtml(const ABody: string): string;
    procedure BtnRefreshPreviewClick(Sender: TObject);
    procedure BtnViewSourceClick(Sender: TObject);
    function GetPreviewSource: string;
    procedure ShowPreviewSource;
    procedure CleanupPreviewTempFiles;
    function PreviewImageUrl(const AFile: string): string;
    function PreviewCssUrl(const AFile: string): string;
    function PreviewMediaUrl(const AFile, AId: string): string;
    function PreviewMediaFile(const AFile: string): string;
    procedure RefreshMediaPanel;
    procedure MediaComboChange(Sender: TObject);
    function FixImageSources(const AHtml: string): string;

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
    { SynEdit 智能提示：输入 { 时弹出资源候选 }
    procedure ProposalExecute(Kind: SynCompletionType; Sender: TObject;
      var CurrentInput: UnicodeString; var x, y: Integer; var CanExecute: Boolean);
    procedure ProposalAfterCodeCompletion(Sender: TObject;
      const Value: UnicodeString; Shift: TShiftState; Index: Integer;
      EndToken: WideChar);
    { 智能提示选中项变化：在 TPanel 中实时预览图片候选 }
    procedure ProposalChange(Sender: TObject; AIndex: Integer);
    procedure ProposalClose(Sender: TObject);
    procedure ShowImagePreview(const AFile: string; AMaxWidth: Integer);
    procedure HideImagePreview;
    procedure PlacePreviewPanel(APanelW, APanelH: Integer);
    procedure LoadPreviewDock;
    procedure SavePreviewDock;
    procedure CboPreviewDockChange(Sender: TObject);
    function PreviewDockToStr(ADock: TPreviewDock): string;
    function StrToPreviewDock(const S: string): TPreviewDock;
    { 同步添加一个候选项及其对应的图片文件路径（空串表示非图片） }
    procedure AppendProposalItem(const ADisplay, AInsert, AImageFile: string);

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
    { 构建“选择要插入的资源”弹窗（底部按钮区独立面板，避免被窗体边框裁切） }
    function CreatePickerDialog(const ACaption: string; AItems: TStrings): TForm;
    { 从下拉项“显示名 (bcp47)”中提取语言代码；无括号时原样返回以支持自定义 }
    function LanguageCodeOf(const AText: string): string;
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

{ 应用工作区 SynEdit 自带 HTML 高亮器的配色；章节编辑器与源代码查看器共用 }
procedure ApplyHtmlHighlightColors(AHighlighter: TSynHTMLSyn);
begin
  if AHighlighter = nil then Exit;
  with AHighlighter do
  begin
    KeyAttri.Foreground := clBlue;
    KeyAttri.Background := clWhite;
    KeyAttri.Style := [fsBold];
    UndefKeyAttri.Foreground := clNavy;
    IdentifierAttri.Foreground := clWindowText;
    CommentAttri.Foreground := clGreen;
    CommentAttri.Style := [fsItalic];
    TextAttri.Foreground := $00404040;
    ValueAttri.Foreground := clRed;
    SymbolAttri.Foreground := $00808080;
    AndAttri.Foreground := $00800080;
    SpaceAttri.Foreground := clWindowText;
  end;
end;

  { HTML 标签记录（行/列均为 1-based，Beg='<'，Fin='>'） }
  type
  THtmlTagRec = record
    Name: string;          { 小写标签名 }
    IsClose: Boolean;      { 是否为结束标签 </...> }
    VoidOrSelf: Boolean;   { 空元素或自闭合，无配对 }
    Beg: TBufferCoord;
    Fin: TBufferCoord;
  end;
  THtmlTagArray = array of THtmlTagRec;

  function IsVoidHtmlTag(const AName: string): Boolean;
  const
    VoidTags = ',area,base,br,col,embed,hr,img,input,link,meta,param,source,track,wbr,';
  begin
    Result := Pos(',' + AName + ',', VoidTags) > 0;
  end;

  { 扫描全部行，按文档顺序返回标签数组；跳过注释、声明、处理指令；
    解析标签名时忽略引号内的 '>'，以正确处理带属性的开始标签 }
  function ParseHtmlTags(ALines: TStrings): THtmlTagArray;
  var
    L, I, J, K, N, NameStart, NameLen: Integer;
    S, Name: string;
    IsClose, SelfClose: Boolean;
    InQuote: Char;
  begin
    SetLength(Result, 0);
    if ALines = nil then Exit;
    for L := 0 to ALines.Count - 1 do
    begin
      S := ALines[L];
      I := 1;
      while I <= Length(S) do
      begin
        if S[I] <> '<' then begin Inc(I); Continue; end;
        if Copy(S, I, 4) = '<!--' then
        begin
          J := PosEx('-->', S, I + 4);
          if J > 0 then I := J + 3 else Break;
          Continue;
        end;
        if (I < Length(S)) and ((S[I + 1] = '!') or (S[I + 1] = '?')) then
        begin
          J := I + 1;
          while (J <= Length(S)) and (S[J] <> '>') do Inc(J);
          if J > Length(S) then Break;
          I := J + 1;
          Continue;
        end;
        IsClose := False;
        NameStart := I + 1;
        if (NameStart <= Length(S)) and (S[NameStart] = '/') then
        begin
          IsClose := True;
          Inc(NameStart);
        end;
        NameLen := 0;
        while (NameStart + NameLen <= Length(S)) and
              (S[NameStart + NameLen] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', ':']) do
          Inc(NameLen);
        if NameLen = 0 then begin Inc(I); Continue; end;
        Name := LowerCase(Copy(S, NameStart, NameLen));

        InQuote := #0;
        J := NameStart + NameLen;
        while J <= Length(S) do
        begin
          if InQuote <> #0 then
          begin
            if S[J] = InQuote then InQuote := #0;
          end
          else if (S[J] = '"') or (S[J] = '''') then InQuote := S[J]
          else if S[J] = '>' then Break;
          Inc(J);
        end;
        if J > Length(S) then Break;  { 跨行标签：不解析 }
        SelfClose := (J > I + 1) and (S[J - 1] = '/');

        N := Length(Result);
        SetLength(Result, N + 1);
        Result[N].Name := Name;
        Result[N].IsClose := IsClose;
        Result[N].VoidOrSelf := SelfClose or IsVoidHtmlTag(Name);
        Result[N].Beg.Line := L + 1;
        Result[N].Beg.Char := I;
        Result[N].Fin.Line := L + 1;
        Result[N].Fin.Char := J;
        I := J + 1;
      end;
    end;
  end;

{------------------------------------------------------------------------------
  HTML 源码格式化排版
  规则：块级标签独占一行并按嵌套层级缩进；短小的纯文本/内联元素内容折叠在
  同一行；注释、DOCTYPE 独占一行；pre/script/style 的内容原样保留并逐行缩进。
------------------------------------------------------------------------------}

type
  THtmlFmtTokenKind = (hftText, hftOpen, hftClose, hftSelfClose,
    hftComment, hftDoctype, hftRaw);
  THtmlFmtToken = record
    Kind: THtmlFmtTokenKind;
    Name: string;          { 小写标签名 }
    Text: string;          { 原始片段 }
    IsBlock: Boolean;      { 是否为块级标签 }
  end;
  THtmlFmtTokenArray = array of THtmlFmtToken;

function IsBlockHtmlTag(const AName: string): Boolean;
const
  BlockTags =
    ',html,head,body,title,meta,link,style,script,div,p,h1,h2,h3,h4,h5,h6,' +
    'ul,ol,li,dl,dt,dd,table,caption,thead,tbody,tfoot,tr,td,th,' +
    'form,fieldset,legend,section,article,aside,header,footer,nav,main,' +
    'figure,figcaption,blockquote,pre,address,details,summary,dialog,' +
    'audio,video,source,track,iframe,canvas,svg,math,hr,center,fieldset,';
begin
  Result := Pos(',' + AName + ',', BlockTags) > 0;
end;

{ 把 HTML 切分为标签/文本/注释等 token；引号内的 '>' 不当作标签结束 }
procedure TokenizeForFormat(const ASource: string; out Tokens: THtmlFmtTokenArray);
var
  S: string;
  I, J, TextStart, NameStart, NameLen, ClosePos: Integer;
  Name, TagText: string;
  IsClose, SelfClose: Boolean;

  procedure AddTok(AKind: THtmlFmtTokenKind; const AName, AText: string);
  var N: Integer;
  begin
    N := Length(Tokens);
    SetLength(Tokens, N + 1);
    Tokens[N].Kind := AKind;
    Tokens[N].Name := LowerCase(AName);
    Tokens[N].Text := AText;
    Tokens[N].IsBlock := IsBlockHtmlTag(LowerCase(AName));
  end;

  function FindTagEnd(AFrom: Integer): Integer;
  var Q: Integer; QQuote: Char;
  begin
    QQuote := #0;
    Q := AFrom;
    while Q <= Length(S) do
    begin
      if QQuote <> #0 then
      begin
        if S[Q] = QQuote then QQuote := #0;
      end
      else if (S[Q] = '"') or (S[Q] = '''') then QQuote := S[Q]
      else if S[Q] = '>' then Exit(Q);
      Inc(Q);
    end;
    Result := 0;
  end;

begin
  SetLength(Tokens, 0);
  S := StringReplace(ASource, #13#10, #10, [rfReplaceAll]);
  S := StringReplace(S, #13, #10, [rfReplaceAll]);
  I := 1;
  TextStart := 1;
  while I <= Length(S) do
  begin
    if S[I] <> '<' then begin Inc(I); Continue; end;
    if I > TextStart then
      AddTok(hftText, '', Copy(S, TextStart, I - TextStart));

    if Copy(S, I, 4) = '<!--' then
    begin
      J := PosEx('-->', S, I + 4);
      if J = 0 then
      begin
        AddTok(hftText, '', Copy(S, I, MaxInt));
        Break;
      end;
      AddTok(hftComment, '', Copy(S, I, J - I + 3));
      I := J + 3;
      TextStart := I;
      Continue;
    end;

    if (I < Length(S)) and ((S[I + 1] = '!') or (S[I + 1] = '?')) then
    begin
      J := FindTagEnd(I + 2);
      if J = 0 then
      begin
        AddTok(hftText, '', Copy(S, I, MaxInt));
        Break;
      end;
      AddTok(hftDoctype, '', Copy(S, I, J - I + 1));
      I := J + 1;
      TextStart := I;
      Continue;
    end;

    IsClose := False;
    NameStart := I + 1;
    if (NameStart <= Length(S)) and (S[NameStart] = '/') then
    begin
      IsClose := True;
      Inc(NameStart);
    end;
    NameLen := 0;
    while (NameStart + NameLen <= Length(S)) and
          (S[NameStart + NameLen] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', ':']) do
      Inc(NameLen);
    if NameLen = 0 then
    begin
      AddTok(hftText, '', '<');   { 孤立的 '<' 视为普通文本 }
      Inc(I);
      TextStart := I;
      Continue;
    end;
    Name := LowerCase(Copy(S, NameStart, NameLen));
    J := FindTagEnd(NameStart + NameLen);
    if J = 0 then
    begin
      AddTok(hftText, '', Copy(S, I, MaxInt));
      Break;
    end;
    TagText := Copy(S, I, J - I + 1);
    SelfClose := (Length(TagText) >= 2) and (TagText[Length(TagText) - 1] = '/');
    if IsClose then
      AddTok(hftClose, Name, TagText)
    else if SelfClose or IsVoidHtmlTag(Name) then
      AddTok(hftSelfClose, Name, TagText)
    else
      AddTok(hftOpen, Name, TagText);

    I := J + 1;
    TextStart := I;

    { pre/script/style 内部可能含 '<' 或类似标签的文本，整段原样保护 }
    if (not IsClose) and (not SelfClose) and
       ((Name = 'pre') or (Name = 'script') or (Name = 'style')) then
    begin
      ClosePos := Pos('</' + Name, LowerCase(Copy(S, I, MaxInt)));
      if ClosePos > 0 then
      begin
        ClosePos := I + ClosePos - 1;
        AddTok(hftRaw, '', Copy(S, I, ClosePos - I));
        I := ClosePos;
        TextStart := I;
      end;
    end;
  end;
  if TextStart <= Length(S) then
    AddTok(hftText, '', Copy(S, TextStart, MaxInt));
end;

{ 折叠文本片段中的空白：连续的空格/换行/制表符合并为单个空格 }
function NormalizeFormatText(const AText: string): string;
var I: Integer; C: Char; SB: TStringBuilder; LastSpace: Boolean;
begin
  SB := TStringBuilder.Create;
  try
    LastSpace := False;
    for I := 1 to Length(AText) do
    begin
      C := AText[I];
      if C in [#9, #10, #13, ' '] then
      begin
        if (SB.Length > 0) and (not LastSpace) then
        begin
          SB.Append(' ');
          LastSpace := True;
        end;
      end
      else
      begin
        SB.Append(C);
        LastSpace := False;
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function FindMatchingFormatClose(const Tokens: THtmlFmtTokenArray;
  AOpen: Integer): Integer;
var I, Depth: Integer; N: string;
begin
  Result := -1;
  N := Tokens[AOpen].Name;
  Depth := 1;
  for I := AOpen + 1 to High(Tokens) do
    if (Tokens[I].Name = N) and (Tokens[I].Kind in [hftOpen, hftClose]) then
    begin
      if Tokens[I].Kind = hftOpen then Inc(Depth)
      else
      begin
        Dec(Depth);
        if Depth = 0 then Exit(I);
      end;
    end;
end;

{ 判断一对标签之间的内容是否短小且只含文本/内联元素（可折叠为一行） }
function IsSimpleFormatRange(const Tokens: THtmlFmtTokenArray;
  AOpen, AClose: Integer): Boolean;
var I, Total: Integer;
begin
  Total := 0;
  for I := AOpen + 1 to AClose - 1 do
  begin
    case Tokens[I].Kind of
      hftText:
        Inc(Total, Length(NormalizeFormatText(Tokens[I].Text)));
      hftOpen, hftClose, hftSelfClose:
        begin
          if Tokens[I].IsBlock then Exit(False);
          Inc(Total, Length(Tokens[I].Text));
        end;
    else
      Exit(False);   { 注释 / DOCTYPE / 原样片段：强制多行 }
    end;
    if Total > 180 then Exit(False);
  end;
  Result := True;
end;

function FormatHtmlSource(const ASource: string): string;
var
  Tokens: THtmlFmtTokenArray;
  Lines, Stack: TStringList;
  Cur, Norm, RawPart: string;
  Indent, I, J, K, Matching, P: Integer;
  Tok: THtmlFmtToken;

  procedure Flush;
  begin
    if Trim(Cur) <> '' then
      Lines.Add(StringOfChar(' ', Indent * 2) + TrimRight(Cur));
    Cur := '';
  end;

  procedure AppendNormText(const ARaw: string);
  begin
    Norm := NormalizeFormatText(ARaw);
    if Norm = '' then Exit;
    if (Cur <> '') and (ARaw <> '') and (ARaw[1] in [#9, #10, #13, ' ']) and
       (Cur[Length(Cur)] <> ' ') then
      Norm := ' ' + Norm
    else if (Cur <> '') and (Norm[1] = ' ') and (Cur[Length(Cur)] = ' ') then
      Delete(Norm, 1, 1);
    Cur := Cur + Norm;
  end;

  procedure AppendRawLines(const ARaw: string);
  var L: Integer;
  begin
    RawPart := Trim(ARaw);
    L := 1;
    while L <= Length(RawPart) do
    begin
      P := L;
      while (P <= Length(RawPart)) and (RawPart[P] <> #10) do Inc(P);
      Lines.Add(StringOfChar(' ', Indent * 2) + TrimRight(Copy(RawPart, L, P - L)));
      L := P + 1;
    end;
  end;

begin
  TokenizeForFormat(ASource, Tokens);
  Lines := TStringList.Create;
  Stack := TStringList.Create;
  try
    Indent := 0;
    Cur := '';
    I := 0;
    while I <= High(Tokens) do
    begin
      Tok := Tokens[I];
      case Tok.Kind of
        hftText:
          AppendNormText(Tok.Text);
        hftComment, hftDoctype:
          begin
            Flush;
            Lines.Add(StringOfChar(' ', Indent * 2) + Tok.Text);
          end;
        hftRaw:
          begin
            Flush;
            AppendRawLines(Tok.Text);
          end;
        hftOpen:
          begin
            if Tok.IsBlock then
            begin
              Matching := FindMatchingFormatClose(Tokens, I);
              if (Matching > I) and IsSimpleFormatRange(Tokens, I, Matching) then
              begin
                { 块级元素内容短小：整体作为一行输出，缩进在闭合标签回退前确定 }
                Flush;
                Cur := Tok.Text;
                for K := I + 1 to Matching - 1 do
                  if Tokens[K].Kind = hftText then
                    AppendNormText(Tokens[K].Text)
                  else
                    Cur := Cur + Tokens[K].Text;
                Cur := Cur + Tokens[Matching].Text;
                Flush;
                I := Matching + 1;
                Continue;
              end;
              Flush;
              Lines.Add(StringOfChar(' ', Indent * 2) + Tok.Text);
              Inc(Indent);
              Stack.Add(Tok.Name);
            end
            else
              Cur := Cur + Tok.Text;
          end;
        hftClose:
          begin
            if Tok.IsBlock then
            begin
              J := Stack.IndexOf(Tok.Name);
              if J >= 0 then
              begin
                Dec(Indent, Stack.Count - J);
                if Indent < 0 then Indent := 0;
                for K := Stack.Count - 1 downto J do Stack.Delete(K);
              end
              else if Indent > 0 then Dec(Indent);
              Flush;
              Lines.Add(StringOfChar(' ', Indent * 2) + Tok.Text);
            end
            else
              Cur := Cur + Tok.Text;
          end;
        hftSelfClose:
          begin
            if Tok.IsBlock then
            begin
              Flush;
              Lines.Add(StringOfChar(' ', Indent * 2) + Tok.Text);
            end
            else
              Cur := Cur + Tok.Text;
          end;
      end;
      Inc(I);
    end;
    Flush;
    Result := Lines.Text;
  finally
    Stack.Free;
    Lines.Free;
  end;
end;

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
  TViewSourceForm —— 查看 FPreviewBrowser 当前 HTML 源代码
------------------------------------------------------------------------------}

constructor TViewSourceForm.Create(AOwner: TComponent);
var
  Bottom: TPanel;
  B: TButton;
begin
  inherited CreateNew(AOwner, 0);
  Caption := 'HTML 源代码';
  Width := 940;
  Height := 660;
  Position := poMainFormCenter;

  { 与章节编辑器共用同一自定义高亮器，查看源代码时占位符同样按类型着色 }
  FSourceHighlighter := TSynEpubPlaceholderSyn.Create(Self);
  ApplyHtmlHighlightColors(FSourceHighlighter);

  FSourceEditor := TSynEdit.Create(Self);
  FSourceEditor.Parent := Self;
  FSourceEditor.Align := alClient;
  FSourceEditor.ReadOnly := True;
  FSourceEditor.WordWrap := False;
  FSourceEditor.ScrollBars := ssBoth;
  FSourceEditor.Highlighter := FSourceHighlighter;
  FSourceEditor.Font.Name := 'Consolas';
  FSourceEditor.Font.Size := 10;
  { 点击标签时用选区浅灰底色高亮；前景色用 clNone 保留高亮器原有语法着色 }
  FSourceEditor.SelectedColor.Background := $00F0F0F0;  { 浅灰 (BGR) }
  FSourceEditor.SelectedColor.Foreground := clNone;
  FSourceEditor.OnMouseDown := SourceEditorMouseDown;
  FSourceEditor.OnMouseUp := SourceEditorMouseUp;

  Bottom := TPanel.Create(Self);
  Bottom.Parent := Self;
  Bottom.Align := alBottom;
  Bottom.Height := 44;
  Bottom.BevelOuter := bvNone;

  B := TButton.Create(Self);
  B.Parent := Bottom;
  B.Caption := '复制全部';
  B.Left := 12;
  B.Top := 6;
  B.Width := 96;
  B.Height := 30;
  B.OnClick := BtnCopyClick;

  B := TButton.Create(Self);
  B.Parent := Bottom;
  B.Caption := '关闭';
  B.Left := 120;
  B.Top := 6;
  B.Width := 96;
  B.Height := 30;
  B.OnClick := BtnCloseClick;

  FFormatButton := TButton.Create(Self);
  FFormatButton.Parent := Bottom;
  FFormatButton.Caption := '格式化排版';
  FFormatButton.Left := 228;
  FFormatButton.Top := 6;
  FFormatButton.Width := 110;
  FFormatButton.Height := 30;
  FFormatButton.Hint := '按 HTML 层级缩进排版；再次点击可恢复原始源码';
  FFormatButton.ShowHint := True;
  FFormatButton.OnClick := BtnFormatClick;

  FStatusLabel := TLabel.Create(Self);
  FStatusLabel.Parent := Bottom;
  FStatusLabel.Left := 348;
  FStatusLabel.Top := 12;
  FStatusLabel.Width := 560;
  FStatusLabel.AutoSize := False;
  FStatusLabel.Caption := '点击源码中的标签可高亮其成对区域';

  FOriginalSource := '';
  FIsFormatted := False;
end;

procedure TViewSourceForm.BtnCopyClick(Sender: TObject);
begin
  FSourceEditor.SelectAll;
  FSourceEditor.CopyToClipboard;
  FSourceEditor.SelStart := 0;
end;

procedure TViewSourceForm.BtnCloseClick(Sender: TObject);
begin
  ModalResult := mrOK;
end;

procedure TViewSourceForm.SetSource(const ASource: string);
begin
  FOriginalSource := ASource;
  FIsFormatted := False;
  FSourceEditor.Lines.Text := ASource;
  FSourceEditor.SelStart := 0;
  if FFormatButton <> nil then
    FFormatButton.Caption := '格式化排版';
  UpdateFormatStatus('共 ' + FSourceEditor.Lines.Count.ToString +
    ' 行；点击源码中的标签可高亮其成对区域');
end;

procedure TViewSourceForm.UpdateFormatStatus(const S: string);
begin
  if FStatusLabel <> nil then FStatusLabel.Caption := S;
end;

function TViewSourceForm.FormatSource: Boolean;
var Formatted: string;
begin
  Result := False;
  try
    Formatted := FormatHtmlSource(FSourceEditor.Lines.Text);
    FSourceEditor.Lines.Text := Formatted;
    FIsFormatted := True;
    if FFormatButton <> nil then FFormatButton.Caption := '恢复原始';
    UpdateFormatStatus('已按层级排版为 ' + FSourceEditor.Lines.Count.ToString + ' 行');
    Result := True;
  except
    on E: Exception do UpdateFormatStatus('格式化失败：' + E.Message);
  end;
  FSourceEditor.SelStart := 0;
end;

function TViewSourceForm.RestoreSource: Boolean;
begin
  FSourceEditor.Lines.Text := FOriginalSource;
  FIsFormatted := False;
  if FFormatButton <> nil then FFormatButton.Caption := '格式化排版';
  UpdateFormatStatus('已恢复原始源码，共 ' + FSourceEditor.Lines.Count.ToString + ' 行');
  FSourceEditor.SelStart := 0;
  Result := True;
end;

function TViewSourceForm.IsFormatted: Boolean;
begin
  Result := FIsFormatted;
end;

procedure TViewSourceForm.BtnFormatClick(Sender: TObject);
begin
  if FIsFormatted then RestoreSource
  else FormatSource;
end;

procedure TViewSourceForm.SourceEditorMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FMouseDownPt := Point(X, Y);
end;

procedure TViewSourceForm.SourceEditorMouseUp(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  { 拖选复制时不覆盖用户选区：仅单击（位移小于拖动阈值）才做标签高亮 }
  if (Abs(X - FMouseDownPt.X) >= 4) or (Abs(Y - FMouseDownPt.Y) >= 4) then
    Exit;
  { 不在鼠标事件中直接改选区：SynEdit 的 MouseUp 后续还会设置块起点/终点，
    会覆盖我们的选区。投递到窗体消息队列，待其处理完再设置。 }
  FClickedPoint := Point(X, Y);
  PostMessage(Handle, WM_APP + $11, 0, 0);
end;

procedure TViewSourceForm.WMSetTagSelection(var Message: TMessage);
begin
  SelectTagAt(FClickedPoint);
end;

{ 通用：把 APoint 处的成对 HTML 标签整体设为选区（浅灰高亮由 SelectedColor 决定）。
  查看源代码窗体与章节管理编辑器共用同一实现，保证行为一致。 }
procedure SelectPairedTagInEditor(AEditor: TSynEdit; const APoint: TPoint);
var
  DisplayPos: TDisplayCoord;
  BufferPos, BegPos, FinPos: TBufferCoord;
  Tags: THtmlTagArray;
  I, Clicked, Depth, OpenIdx, CloseIdx: Integer;
  TagName: string;
  Paired: Boolean;
begin
  if AEditor = nil then Exit;
  DisplayPos := AEditor.PixelsToRowColumn(APoint.X, APoint.Y);
  BufferPos := AEditor.DisplayToBufferPos(DisplayPos);
  if (BufferPos.Line < 1) or (BufferPos.Line > AEditor.Lines.Count) then
    Exit;

  Tags := ParseHtmlTags(AEditor.Lines);
  if Length(Tags) = 0 then Exit;

  { 定位点击落在哪个标签上（开始或结束标签均可） }
  Clicked := -1;
  for I := 0 to High(Tags) do
    if (Tags[I].Beg.Line = BufferPos.Line) and
       (BufferPos.Char >= Tags[I].Beg.Char) and
       (BufferPos.Char <= Tags[I].Fin.Char) then
    begin
      Clicked := I;
      Break;
    end;
  if Clicked < 0 then Exit;  { 未点中标签，保留当前选区 }

  TagName := Tags[Clicked].Name;
  OpenIdx := Clicked;
  CloseIdx := Clicked;
  Paired := False;

  { 空元素/自闭合标签没有配对，仅高亮自身 }
  if not Tags[Clicked].VoidOrSelf then
  begin
    if not Tags[Clicked].IsClose then
    begin
      { 点在开始标签：向后用深度计数找匹配的结束标签 }
      Depth := 1;
      for I := Clicked + 1 to High(Tags) do
        if (Tags[I].Name = TagName) and (not Tags[I].VoidOrSelf) then
        begin
          if Tags[I].IsClose then
          begin
            Dec(Depth);
            if Depth = 0 then
            begin
              CloseIdx := I;
              Paired := True;
              Break;
            end;
          end
          else
            Inc(Depth);  { 同名嵌套开始标签 }
        end;
    end
    else
    begin
      { 点在结束标签：向前用深度计数找匹配的开始标签 }
      Depth := 1;
      for I := Clicked - 1 downto 0 do
        if (Tags[I].Name = TagName) and (not Tags[I].VoidOrSelf) then
        begin
          if not Tags[I].IsClose then
          begin
            Dec(Depth);
            if Depth = 0 then
            begin
              OpenIdx := I;
              Paired := True;
              Break;
            end;
          end
          else
            Inc(Depth);  { 同名嵌套结束标签 }
        end;
    end;
  end;

  { 选区从开始标签 '<' 覆盖到结束标签 '>' 之后（开区间），包含整对标签及其内容 }
  BegPos := Tags[OpenIdx].Beg;
  FinPos := Tags[CloseIdx].Fin;
  AEditor.SelStart := AEditor.RowColToCharIndex(BegPos);
  FinPos.Char := FinPos.Char + 1;  { SynEdit 选区终点为开区间 }
  if Paired and
     (FinPos.Char > AEditor.Lines[FinPos.Line - 1].Length + 1) then
  begin
    FinPos.Line := FinPos.Line + 1;
    FinPos.Char := 1;
  end;
  AEditor.SelEnd := AEditor.RowColToCharIndex(FinPos);
end;

procedure TViewSourceForm.SelectTagAt(const APoint: TPoint);
begin
  SelectPairedTagInEditor(FSourceEditor, APoint);
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
  FLastPreviewHtml := '';
  FPreviewCopyIndex := 0;
  SetLength(FPreviewTempFiles, 0);
  FMediaPreviewFiles := TDictionary<string, string>.Create;

  BuildUi;
  LoadSample(True);
end;

destructor TMainForm.Destroy;
begin
  if Assigned(FMediaPlayer) then
  begin
    try FMediaPlayer.Close; except end;
  end;
  CleanupPreviewTempFiles;
  FMediaPreviewFiles.Free;
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
  Page.Caption := 'HTML 预览';
  CreatePreviewTab(Page);

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
  FCboLanguage := TComboBox.Create(Self);
  FCboLanguage.Parent := P;
  FCboLanguage.Left := 110;
  FCboLanguage.Top := 88;
  FCboLanguage.Width := 160;
  FCboLanguage.Style := csDropDown;  { 可选常用语言，也允许自定义 BCP 47 标签 }
  FCboLanguage.Items.Add('简体中文 (zh-CN)');
  FCboLanguage.Items.Add('繁體中文 (zh-TW)');
  FCboLanguage.Items.Add('英语 (en-US)');
  FCboLanguage.Items.Add('英语-英国 (en-GB)');
  FCboLanguage.Items.Add('日语 (ja-JP)');
  FCboLanguage.Items.Add('韩语 (ko-KR)');
  FCboLanguage.Items.Add('法语 (fr-FR)');
  FCboLanguage.Items.Add('德语 (de-DE)');
  FCboLanguage.Items.Add('西班牙语 (es-ES)');
  FCboLanguage.Items.Add('葡萄牙语 (pt-BR)');
  FCboLanguage.Items.Add('俄语 (ru-RU)');
  FCboLanguage.Items.Add('意大利语 (it-IT)');
  FCboLanguage.Items.Add('阿拉伯语 (ar-SA)');
  FCboLanguage.Items.Add('印地语 (hi-IN)');
  FCboLanguage.Items.Add('泰语 (th-TH)');
  FCboLanguage.Items.Add('越南语 (vi-VN)');
  FCboLanguage.ItemIndex := 0;
  MakeLabel(Self, P, '标识符（留空自动生成 UUID）', 300, 92, 200);
  FEdIdentifier := MakeEdit(Self, P, 510, 88, 300);

  MakeLabel(Self, P, '出版社', 16, 128, 60);
  FEdPublisher := MakeEdit(Self, P, 110, 124, 700);

  MakeLabel(Self, P, '主题', 16, 164, 60);
  FEdSubject := MakeEdit(Self, P, 110, 160, 700);

  MakeLabel(Self, P, '出版日期', 16, 200, 70);
  FEdDate := TDateTimePicker.Create(Self);
  FEdDate.Parent := P;
  FEdDate.Left := 110;
  FEdDate.Top := 194;
  FEdDate.Width := 200;
  FEdDate.Kind := dtkDate;
  FEdDate.DateFormat := dfShort;
  FEdDate.Format := 'yyyy-MM-dd';  { 固定 EPUB 使用的 ISO 日期格式，下拉日历可选日期 }
  FEdDate.Date := Now;
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
  MakeLabel(Self, InsertPanel, '占位符 →', 0, 10, 62);
  MakeButton(Self, InsertPanel, '图片', 62, 4, 60, 30, BtnInsertImageClick);
  MakeButton(Self, InsertPanel, '音频', 126, 4, 60, 30, BtnInsertAudioClick);
  MakeButton(Self, InsertPanel, '视频', 190, 4, 60, 30, BtnInsertVideoClick);
  MakeButton(Self, InsertPanel, '章节链接', 254, 4, 76, 30, BtnInsertLinkClick);
  MakeButton(Self, InsertPanel, '字体设置', 344, 4, 76, 30, BtnFontSettingsClick);
  MakeButton(Self, InsertPanel, '格式化排版', 424, 4, 88, 30, BtnFormatChapterClick);
  MakeButton(Self, InsertPanel, '预览效果', 516, 4, 76, 30, BtnRefreshPreviewClick);

  { 图片预览面板停靠位置选择 }
  MakeLabel(Self, InsertPanel, '预览位置', 600, 10, 56);
  FCboPreviewDock := TComboBox.Create(Self);
  FCboPreviewDock.Parent := InsertPanel;
  FCboPreviewDock.Left := 658;
  FCboPreviewDock.Top := 4;
  FCboPreviewDock.Width := 110;
  FCboPreviewDock.Height := 26;
  FCboPreviewDock.Style := csDropDownList;
  FCboPreviewDock.Items.Add('自动（智能）');
  FCboPreviewDock.Items.Add('列表左侧');
  FCboPreviewDock.Items.Add('列表顶部');
  FCboPreviewDock.Items.Add('列表右侧');
  FCboPreviewDock.Items.Add('列表底部');
  FCboPreviewDock.OnChange := CboPreviewDockChange;

  { 占位符样式：按图片 / 音频 / 视频 / 章节链接 / 未知类型分别设置
    前景色、背景色与字型，写入自定义 TSynCustomHighlighter 派生类 }
  MakeButton(Self, InsertPanel, '占位符样式', 780, 4, 100, 30,
    BtnPlaceholderStyleClick);
  MakeLabel(Self, InsertPanel, '占位符可分类着色', 888, 10, 120);

  { 章节内容编辑器：SynEdit + 自定义高亮器
    （TSynCustomHighlighter 派生：完整 HTML 着色 + 占位符按类型分类样式） }
  FPlaceholderHighlighter := TSynEpubPlaceholderSyn.Create(Self);
  FHtmlHighlighter := FPlaceholderHighlighter;  { 保持既有 TSynHTMLSyn 接口兼容 }
  ConfigureHtmlHighlighter;

  FSynEditor := TSynEdit.Create(Self);
  FSynEditor.Parent := EditPanel;
  FSynEditor.Align := alClient;
  FSynEditor.ScrollBars := ssBoth;
  FSynEditor.WordWrap := False;
  FSynEditor.Highlighter := FHtmlHighlighter;
  FSynEditor.Font.Name := '宋体';
  FSynEditor.Font.Size := 12;
  FSynEditor.Color := clWhite;
  FSynEditor.Font.Color := clWindowText;
  LoadEditorFont;  { 若有保存的自定义字体配置则覆盖默认值 }
  FSynEditor.Gutter.Width := 34;
  FSynEditor.Gutter.Visible := True;
  FSynEditor.Gutter.ShowLineNumbers := True;
  FSynEditor.Gutter.Color := $00F0F0F0;
  FSynEditor.Options := FSynEditor.Options + [eoShowSpecialChars];
  FSynEditor.OnChange := EditorChanged;
  { 点击成对 HTML 标签整体浅灰高亮：与“查看源代码”窗体使用同一套逻辑 }
  FSynEditor.SelectedColor.Background := $00F0F0F0;
  FSynEditor.SelectedColor.Foreground := clNone;
  FSynEditor.OnMouseDown := ChapterEditorMouseDown;
  FSynEditor.OnMouseUp := ChapterEditorMouseUp;

  { 输入 { 时自动弹出资源智能提示（TriggerChars + 内置定时器） }
  FResourceProposal := TSynCompletionProposal.Create(Self);
  FResourceProposal.Editor := FSynEditor;
  FResourceProposal.Options := [scoUseInsertList, scoCompleteWithEnter,
    scoCompleteWithTab, scoUseBuiltInTimer, scoLimitToMatchedTextAnywhere];
  FResourceProposal.TriggerChars := '{';
  FResourceProposal.TimerInterval := 120;
  FResourceProposal.EndOfTokenChr := '}/>';
  FResourceProposal.Title := '可插入的资源 / 占位符（↑↓ 选择，Enter 插入，Esc 取消）';
  FResourceProposal.Width := 500;
  FResourceProposal.NbLinesInWindow := 12;
  FResourceProposal.ClSelect := $00C86020;
  FResourceProposal.ClSelectedText := clWhite;
  FResourceProposal.OnExecute := ProposalExecute;
  FResourceProposal.OnAfterCodeCompletion := ProposalAfterCodeCompletion;
  FResourceProposal.OnChange := ProposalChange;
  FResourceProposal.OnClose := ProposalClose;

  { 图片预览面板：章节编辑页内嵌的普通 TPanel。
    用普通控件而非独立窗体，Visible 切换不会触发窗体的 CMShowingChanged，
    因此不会与补全窗体的 OnShow/OnHide 产生重入；也不会抢占编辑器焦点。
    创建顺序在 FSynEditor 之后，使其浮动显示在编辑器上方。 }
  FImagePreviewPanel := TPanel.Create(Self);
  FImagePreviewPanel.Parent := EditPanel;
  FImagePreviewPanel.Align := alNone;
  FImagePreviewPanel.BevelOuter := bvRaised;
  FImagePreviewPanel.Caption := '';
  FImagePreviewPanel.Color := clWhite;
  FImagePreviewPanel.Padding.SetBounds(2, 2, 2, 2);
  FImagePreviewPanel.Visible := False;

  FPreviewImageLabel := TLabel.Create(Self);
  FPreviewImageLabel.Parent := FImagePreviewPanel;
  FPreviewImageLabel.Align := alTop;
  FPreviewImageLabel.Height := 20;
  FPreviewImageLabel.Font.Style := [fsBold];
  FPreviewImageLabel.Font.Size := 9;
  FPreviewImageLabel.Font.Color := clWhite;
  FPreviewImageLabel.Color := $00A86020;
  FPreviewImageLabel.Transparent := False;
  FPreviewImageLabel.Caption := ' 图片预览';

  FPreviewImage := TImage.Create(Self);
  FPreviewImage.Parent := FImagePreviewPanel;
  FPreviewImage.Align := alClient;
  FPreviewImage.Stretch := True;
  FPreviewImage.Center := True;

  { 加载停靠位置偏好并同步下拉框选择 }
  LoadPreviewDock;
end;

procedure TMainForm.ConfigureHtmlHighlighter;
begin
  { 应用工作区 SynEdit 自带 HTML 高亮器的配色，使章节 XHTML 编辑更美观 }
  ApplyHtmlHighlightColors(FHtmlHighlighter);
end;

function EditorIniPath: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'EditorSettings.ini');
end;

procedure TMainForm.LoadEditorFont;
var
  Ini: TIniFile;
  Path, FName: string;
  FSize, FColor: Integer;
  FStyle: string;
  Styles: TFontStyles;
begin
  Path := EditorIniPath;
  { 占位符分类样式与编辑器字体共用同一配置文件 }
  if Assigned(FPlaceholderHighlighter) then
    FPlaceholderHighlighter.LoadStyleSettings(Path);
  if not TFile.Exists(Path) then
    Exit;
  Ini := TIniFile.Create(Path);
  try
    FName := Ini.ReadString('Editor', 'FontName', '宋体');
    FSize := Ini.ReadInteger('Editor', 'FontSize', 12);
    FColor := Ini.ReadInteger('Editor', 'FontColor', clWindowText);
    FStyle := Ini.ReadString('Editor', 'FontStyle', '');
    if FName <> '' then
      FSynEditor.Font.Name := FName;
    if FSize > 0 then
      FSynEditor.Font.Size := FSize;
    FSynEditor.Font.Color := TColor(FColor);
    Styles := [];
    if Pos('B', FStyle) > 0 then Include(Styles, fsBold);
    if Pos('I', FStyle) > 0 then Include(Styles, fsItalic);
    if Pos('U', FStyle) > 0 then Include(Styles, fsUnderline);
    FSynEditor.Font.Style := Styles;
    { 正文颜色同步到高亮器，确保自定义文字颜色真正可见 }
    FHtmlHighlighter.TextAttri.Foreground := FSynEditor.Font.Color;
    FHtmlHighlighter.IdentifierAttri.Foreground := FSynEditor.Font.Color;
    FHtmlHighlighter.SpaceAttri.Foreground := FSynEditor.Font.Color;
  except
    on E: Exception do
      ;  // 配置损坏时静默使用默认字体
  end;
  Ini.Free;
end;

procedure TMainForm.SaveEditorFont;
var
  Ini: TIniFile;
  FStyle: string;
begin
  Ini := TIniFile.Create(EditorIniPath);
  try
    Ini.WriteString('Editor', 'FontName', FSynEditor.Font.Name);
    Ini.WriteInteger('Editor', 'FontSize', FSynEditor.Font.Size);
    Ini.WriteInteger('Editor', 'FontColor', ColorToRGB(FSynEditor.Font.Color));
    FStyle := '';
    if fsBold in FSynEditor.Font.Style then FStyle := FStyle + 'B';
    if fsItalic in FSynEditor.Font.Style then FStyle := FStyle + 'I';
    if fsUnderline in FSynEditor.Font.Style then FStyle := FStyle + 'U';
    Ini.WriteString('Editor', 'FontStyle', FStyle);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.BtnFontSettingsClick(Sender: TObject);
var
  Dlg: TFontDialog;
begin
  Dlg := TFontDialog.Create(Self);
  try
    Dlg.Font.Assign(FSynEditor.Font);
    if Dlg.Execute then
    begin
      FSynEditor.Font.Assign(Dlg.Font);
      FHtmlHighlighter.TextAttri.Foreground := FSynEditor.Font.Color;
      FHtmlHighlighter.IdentifierAttri.Foreground := FSynEditor.Font.Color;
      FHtmlHighlighter.SpaceAttri.Foreground := FSynEditor.Font.Color;
      SaveEditorFont;
      Log(Format('编辑器字体已更新：%s %dpt 颜色=$%.6x',
        [FSynEditor.Font.Name, FSynEditor.Font.Size,
         ColorToRGB(FSynEditor.Font.Color)]));
      SetStatus('字体：' + FSynEditor.Font.Name + ' ' +
        FSynEditor.Font.Size.ToString + 'pt');
    end;
  finally
    Dlg.Free;
  end;
end;

{------------------------------------------------------------------------------
  占位符分类样式设置
  基于 SynEditHighlighter.pas 的 TSynCustomHighlighter / TSynHighlighterAttributes：
  图片、音频、视频、章节链接、未知占位符各有独立的前景 / 背景 / 字型属性，
  可在界面上分别调整并持久化到 EditorSettings.ini。
------------------------------------------------------------------------------}

procedure TPlaceholderStyleDialog.LoadFromHighlighter;
var
  K: TEpubPlaceholderKind;
  A: TSynHighlighterAttributes;
begin
  for K := Low(TEpubPlaceholderKind) to High(TEpubPlaceholderKind) do
  begin
    A := FHighlighter.AttributeFor(K);
    FFore[K] := A.Foreground;
    FBack[K] := A.Background;
    FStyles[K] := A.Style;
  end;
end;

procedure TPlaceholderStyleDialog.ApplyToHighlighter;
var
  K: TEpubPlaceholderKind;
  A: TSynHighlighterAttributes;
begin
  ChkClick(nil);   { 确保界面上的复选框状态已写回当前类型 }
  for K := Low(TEpubPlaceholderKind) to High(TEpubPlaceholderKind) do
  begin
    A := FHighlighter.AttributeFor(K);
    A.Foreground := FFore[K];
    A.Background := FBack[K];
    A.Style := FStyles[K];
  end;
end;

procedure TPlaceholderStyleDialog.ShowKind(AKind: TEpubPlaceholderKind);
begin
  FCurrent := AKind;
  FCboKind.ItemIndex := Ord(AKind);
  FChkBold.Checked := fsBold in FStyles[AKind];
  FChkItalic.Checked := fsItalic in FStyles[AKind];
  FChkUnderline.Checked := fsUnderline in FStyles[AKind];
  FChkStrike.Checked := fsStrikeOut in FStyles[AKind];
  UpdatePreview;
end;

procedure TPlaceholderStyleDialog.UpdatePreview;
const
  Prefix: array[TEpubPlaceholderKind] of string =
    ('image', 'audio', 'video', 'link', 'custom');
begin
  FPreview.Caption := '  {{' + Prefix[FCurrent] + ':R001}}  ';
  FPreview.Font.Color := FFore[FCurrent];
  FPreview.Font.Style := FStyles[FCurrent];
  FPreview.Color := FBack[FCurrent];
end;

procedure TPlaceholderStyleDialog.CboKindChange(Sender: TObject);
begin
  if FCboKind.ItemIndex < 0 then Exit;
  ChkClick(nil);   { 保存切换前的类型 }
  ShowKind(TEpubPlaceholderKind(FCboKind.ItemIndex));
end;

procedure TPlaceholderStyleDialog.BtnForeClick(Sender: TObject);
var
  D: TColorDialog;
begin
  D := TColorDialog.Create(Self);
  try
    D.Color := FFore[FCurrent];
    if D.Execute then
    begin
      FFore[FCurrent] := D.Color;
      UpdatePreview;
    end;
  finally
    D.Free;
  end;
end;

procedure TPlaceholderStyleDialog.BtnBackClick(Sender: TObject);
var
  D: TColorDialog;
begin
  D := TColorDialog.Create(Self);
  try
    D.Color := FBack[FCurrent];
    if D.Execute then
    begin
      FBack[FCurrent] := D.Color;
      UpdatePreview;
    end;
  finally
    D.Free;
  end;
end;

procedure TPlaceholderStyleDialog.ChkClick(Sender: TObject);
var
  S: TFontStyles;
begin
  S := [];
  if FChkBold.Checked then Include(S, fsBold);
  if FChkItalic.Checked then Include(S, fsItalic);
  if FChkUnderline.Checked then Include(S, fsUnderline);
  if FChkStrike.Checked then Include(S, fsStrikeOut);
  FStyles[FCurrent] := S;
  UpdatePreview;
end;

procedure TPlaceholderStyleDialog.BtnResetClick(Sender: TObject);
var
  Tmp: TSynEpubPlaceholderSyn;
  K: TEpubPlaceholderKind;
  A: TSynHighlighterAttributes;
begin
  { 用全新的高亮器读取出厂默认样式，不直接改动正在使用的实例 }
  Tmp := TSynEpubPlaceholderSyn.Create(nil);
  try
    for K := Low(TEpubPlaceholderKind) to High(TEpubPlaceholderKind) do
    begin
      A := Tmp.AttributeFor(K);
      FFore[K] := A.Foreground;
      FBack[K] := A.Background;
      FStyles[K] := A.Style;
    end;
  finally
    Tmp.Free;
  end;
  ShowKind(FCurrent);
end;

procedure TPlaceholderStyleDialog.Init(AHighlighter: TSynEpubPlaceholderSyn);
begin
  FHighlighter := AHighlighter;
  Caption := '占位符样式设置（TSynCustomHighlighter）';
  Width := 470;
  Height := 300;
  Position := poMainFormCenter;
  BorderStyle := bsDialog;

  MakeLabel(Self, Self, '占位符类型', 16, 14, 80);
  FCboKind := TComboBox.Create(Self);
  FCboKind.Parent := Self;
  FCboKind.Left := 104;
  FCboKind.Top := 10;
  FCboKind.Width := 210;
  FCboKind.Height := 26;
  FCboKind.Style := csDropDownList;
  FCboKind.Items.Add('图片 {{image:...}}');
  FCboKind.Items.Add('音频 {{audio:...}}');
  FCboKind.Items.Add('视频 {{video:...}}');
  FCboKind.Items.Add('章节链接 {{link:...}}');
  FCboKind.Items.Add('未知 / 自定义占位符');
  FCboKind.OnChange := CboKindChange;

  FBtnFore := MakeButton(Self, Self, '前景色…', 16, 48, 100, 30, BtnForeClick);
  FBtnBack := MakeButton(Self, Self, '背景色…', 124, 48, 100, 30, BtnBackClick);

  FChkBold := TCheckBox.Create(Self);
  FChkBold.Parent := Self;
  FChkBold.Caption := '粗体';
  FChkBold.SetBounds(16, 92, 96, 24);
  FChkBold.OnClick := ChkClick;

  FChkItalic := TCheckBox.Create(Self);
  FChkItalic.Parent := Self;
  FChkItalic.Caption := '斜体';
  FChkItalic.SetBounds(116, 92, 96, 24);
  FChkItalic.OnClick := ChkClick;

  FChkUnderline := TCheckBox.Create(Self);
  FChkUnderline.Parent := Self;
  FChkUnderline.Caption := '下划线';
  FChkUnderline.SetBounds(216, 92, 96, 24);
  FChkUnderline.OnClick := ChkClick;

  FChkStrike := TCheckBox.Create(Self);
  FChkStrike.Parent := Self;
  FChkStrike.Caption := '删除线';
  FChkStrike.SetBounds(316, 92, 96, 24);
  FChkStrike.OnClick := ChkClick;

  FPreview := TLabel.Create(Self);
  FPreview.Parent := Self;
  FPreview.SetBounds(16, 132, 424, 42);
  FPreview.AutoSize := False;
  FPreview.Transparent := False;
  FPreview.Alignment := taCenter;
  FPreview.Layout := tlCenter;
  FPreview.Font.Name := '宋体';
  FPreview.Font.Size := 12;

  MakeLabel(Self, Self, '提示：字号由编辑器「字体设置」统一控制', 16, 182, 320);

  MakeButton(Self, Self, '恢复默认', 16, 214, 96, 30, BtnResetClick);
  with MakeButton(Self, Self, '确定', 240, 214, 96, 30, nil) do
  begin
    ModalResult := mrOk;
    Default := True;
  end;
  with MakeButton(Self, Self, '取消', 344, 214, 96, 30, nil) do
  begin
    ModalResult := mrCancel;
    Cancel := True;
  end;

  LoadFromHighlighter;
  ShowKind(pkImage);
end;

function EditPlaceholderStyles(AOwner: TComponent;
  AHighlighter: TSynEpubPlaceholderSyn; const AIniFile: string): Boolean;
var
  Dlg: TPlaceholderStyleDialog;
begin
  Result := False;
  if AHighlighter = nil then Exit;
  Dlg := TPlaceholderStyleDialog.CreateNew(AOwner);
  try
    Dlg.Init(AHighlighter);
    if Dlg.ShowModal = mrOk then
    begin
      Dlg.ApplyToHighlighter;
      AHighlighter.SaveStyleSettings(AIniFile);
      Result := True;
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TMainForm.BtnPlaceholderStyleClick(Sender: TObject);
begin
  if FPlaceholderHighlighter = nil then Exit;
  if EditPlaceholderStyles(Self, FPlaceholderHighlighter, EditorIniPath) then
  begin
    FSynEditor.Invalidate;
    Log('占位符分类样式已更新：图片 / 音频 / 视频 / 章节链接 / 未知 各自的前景、背景与字型');
    SetStatus('占位符样式已更新（保存在 EditorSettings.ini）');
  end;
end;

procedure TMainForm.BtnFormatChapterClick(Sender: TObject);
var
  Original, Formatted: string;
  OldLines: Integer;
begin
  if (FSynEditor = nil) or (not FSynEditor.Enabled) then Exit;
  Original := FSynEditor.Text;
  if Trim(Original) = '' then
  begin
    SetStatus('当前章节内容为空，无需格式化');
    Exit;
  end;

  Formatted := FormatHtmlSource(Original);
  if Formatted = Original then
  begin
    SetStatus('章节源码已符合规范排版');
    Exit;
  end;

  OldLines := FSynEditor.Lines.Count;
  { 整段替换会进入 SynEdit 撤销栈，格式化后仍可用 Ctrl+Z 还原 }
  FSynEditor.SelectAll;
  FSynEditor.SelText := Formatted;
  FSynEditor.SelStart := 0;
  FSynEditor.SelEnd := 0;
  if FSynEditor.CanFocus then FSynEditor.SetFocus;

  Log(Format('章节内容已格式化排版：%d → %d 行',
    [OldLines, FSynEditor.Lines.Count]));
  SetStatus('章节 HTML 已按层级排版：' + OldLines.ToString + ' → ' +
    FSynEditor.Lines.Count.ToString + ' 行（Ctrl+Z 可撤销）');
end;

procedure TMainForm.ChapterEditorMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FEditorMouseDownPt := Point(X, Y);
end;

procedure TMainForm.ChapterEditorMouseUp(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  { 拖选复制时不覆盖用户选区：仅单击（位移小于拖动阈值）才做标签高亮 }
  if (Abs(X - FEditorMouseDownPt.X) >= 4) or
     (Abs(Y - FEditorMouseDownPt.Y) >= 4) then Exit;
  { 不在鼠标事件中直接改选区：SynEdit 的 MouseUp 后续还会设置块起点/终点，
    会覆盖我们的选区。投递到窗体消息队列，待其处理完再设置。 }
  FEditorClickedPoint := Point(X, Y);
  PostMessage(Handle, WM_APP + $12, 0, 0);
end;

procedure TMainForm.WMChapterTagSelection(var Message: TMessage);
begin
  SelectTagInChapterEditor(FEditorClickedPoint);
end;

procedure TMainForm.SelectTagInChapterEditor(const APoint: TPoint);
begin
  SelectPairedTagInEditor(FSynEditor, APoint);
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

procedure TMainForm.CreatePreviewTab(APage: TTabSheet);
var
  Bar: TPanel;
begin
  Bar := TPanel.Create(Self);
  Bar.Parent := APage;
  Bar.Align := alTop;
  Bar.Height := 46;
  Bar.BevelOuter := bvNone;
  Bar.Padding.SetBounds(8, 6, 8, 6);
  MakeLabel(Self, Bar,
    '当前章节正文的实时预览（显示效果以阅读器为准；音视频请用下方播放栏）',
    0, 10, 560);
  MakeButton(Self, Bar, '刷新预览', 600, 4, 90, 30, BtnRefreshPreviewClick);
  MakeButton(Self, Bar, '查看源代码', 698, 4, 100, 30, BtnViewSourceClick);

  { 媒体播放栏：当前 Wke.dll 没有 HTML5 媒体后端，<audio>/<video> 不会加载资源，
    因此用系统解码器（MCI）提供真实可操作的播放控制。 }
  FMediaPanel := TPanel.Create(Self);
  FMediaPanel.Parent := APage;
  FMediaPanel.Align := alBottom;
  FMediaPanel.Height := 72;
  FMediaPanel.BevelOuter := bvNone;
  FMediaPanel.Padding.SetBounds(8, 4, 8, 4);
  MakeLabel(Self, FMediaPanel, '媒体播放（系统解码器）：', 0, 6, 170);
  FMediaCombo := TComboBox.Create(Self);
  FMediaCombo.Parent := FMediaPanel;
  FMediaCombo.Left := 176;
  FMediaCombo.Top := 4;
  FMediaCombo.Width := 360;
  FMediaCombo.Style := csDropDownList;
  FMediaCombo.OnChange := MediaComboChange;
  FMediaPlayer := TMediaPlayer.Create(Self);
  FMediaPlayer.Parent := FMediaPanel;
  FMediaPlayer.Left := 546;
  FMediaPlayer.Top := 2;
  FMediaPanel.Visible := False;

  { 基于 Wke（MiniBlink / Chromium 内核）的浏览器，替换老旧的 IE WebBrowser。
    将 Wke.dll 路径指向 EXE 同目录（默认单元内为 node.dll）。 }
  wkeLibFileName := TPath.Combine(ExtractFilePath(ParamStr(0)), 'Wke.dll');
  FPreviewBrowser := TWkeWebBrowser.Create(Self);
  FPreviewBrowser.Parent := APage;
  FPreviewBrowser.Align := alClient;
end;

function PathToUrl(const APath: string): string;
var
  Utf8: TBytes;
  I: Integer;
  B: Byte;
  S: string;
begin
  S := StringReplace(APath, '\', '/', [rfReplaceAll]);
  Utf8 := TEncoding.UTF8.GetBytes(S);
  Result := 'file:///';
  for I := 0 to High(Utf8) do
  begin
    B := Utf8[I];
    if ((B >= 65) and (B <= 90)) or ((B >= 97) and (B <= 122)) or
       ((B >= 48) and (B <= 57)) or
       (B in [Ord('-'), Ord('_'), Ord('.'), Ord('/'), Ord(':'), Ord('~')]) then
      Result := Result + Chr(B)
    else
      Result := Result + '%' + IntToHex(B, 2);
  end;
end;

function HasNonAscii(const S: string): Boolean;
var I: Integer;
begin
  for I := 1 to Length(S) do
    if S[I] > #127 then Exit(True);
  Result := False;
end;

function TryHexDigit(B: Byte; out V: Integer): Boolean;
begin
  Result := True;
  if (B >= Ord('0')) and (B <= Ord('9')) then V := B - Ord('0')
  else if (B >= Ord('a')) and (B <= Ord('f')) then V := B - Ord('a') + 10
  else if (B >= Ord('A')) and (B <= Ord('F')) then V := B - Ord('A') + 10
  else begin V := 0; Result := False; end;
end;

{ 将 file:/// URL 或 percent 编码路径还原为本地 Unicode 路径 }
function DecodePercentUrl(const S: string): string;
var
  Utf8, OutBytes: TBytes;
  I, J, V1, V2: Integer;
begin
  Utf8 := TEncoding.UTF8.GetBytes(S);
  SetLength(OutBytes, Length(Utf8));
  I := 0;
  J := 0;
  while I < Length(Utf8) do
  begin
    if (Utf8[I] = Ord('%')) and (I + 2 < Length(Utf8)) and
       TryHexDigit(Utf8[I + 1], V1) and TryHexDigit(Utf8[I + 2], V2) then
    begin
      OutBytes[J] := Byte((V1 shl 4) or V2);
      Inc(I, 3);
    end
    else
    begin
      OutBytes[J] := Utf8[I];
      Inc(I);
    end;
    Inc(J);
  end;
  SetLength(OutBytes, J);
  Result := TEncoding.UTF8.GetString(OutBytes);
end;

function FileAsDataUrl(const AFile, AMime: string): string;
var
  Stream: TFileStream;
  Bytes: TBytes;
  Enc: TBase64Encoding;
begin
  Result := '';
  if (AFile = '') or (not TFile.Exists(AFile)) then Exit;
  try
    Stream := TFileStream.Create(AFile, fmOpenRead or fmShareDenyWrite);
  except
    Exit;
  end;
  try
    if Stream.Size > 0 then
    begin
      SetLength(Bytes, Stream.Size);
      Stream.ReadBuffer(Bytes[0], Length(Bytes));
      Enc := TBase64Encoding.Create(0);
      try
        Result := 'data:' + AMime + ';base64,' + Enc.EncodeBytesToString(Bytes);
      finally
        Enc.Free;
      end;
    end;
  finally
    Stream.Free;
  end;
end;

function FindTextCI(const AText, ASub: string; AStart: Integer): Integer;
var I, L: Integer;
begin
  Result := 0;
  L := Length(ASub);
  if (L = 0) or (AStart < 1) then Exit;
  for I := AStart to Length(AText) - L + 1 do
    if SameText(Copy(AText, I, L), ASub) then Exit(I);
end;

procedure TMainForm.CleanupPreviewTempFiles;
var I: Integer;
begin
  for I := 0 to High(FPreviewTempFiles) do
    if FPreviewTempFiles[I] <> '' then
      try
        TFile.Delete(FPreviewTempFiles[I]);
      except
      end;
  SetLength(FPreviewTempFiles, 0);
  if Assigned(FMediaPreviewFiles) then FMediaPreviewFiles.Clear;
end;

function TMainForm.PreviewImageUrl(const AFile: string): string;
begin
  Result := '';
  if AFile = '' then Exit;
  { 中文 / 非 ASCII 路径在 wke 中经 file:/// 解码会失败，直接内嵌为 data URI }
  if HasNonAscii(AFile) then
    Result := FileAsDataUrl(AFile, TEpubGenerator.GuessMimeType(AFile));
  if Result = '' then Result := PathToUrl(AFile);
end;

function TMainForm.PreviewCssUrl(const AFile: string): string;
begin
  Result := '';
  if AFile = '' then Exit;
  if HasNonAscii(AFile) then
    Result := FileAsDataUrl(AFile, 'text/css');
  if Result = '' then Result := PathToUrl(AFile);
end;

function TMainForm.PreviewMediaFile(const AFile: string): string;
var TempFile: string;
begin
  Result := AFile;
  if (AFile = '') or (not HasNonAscii(AFile)) or (not TFile.Exists(AFile)) then Exit;
  { 音视频文件通常较大，复制为纯 ASCII 临时路径，避免 base64 膨胀 HTML }
  Inc(FPreviewCopyIndex);
  TempFile := TPath.Combine(TPath.GetTempPath,
    Format('epub_prev_media_%d_%d%s',
      [GetCurrentProcessId, FPreviewCopyIndex, ExtractFileExt(AFile)]));
  try
    TFile.Copy(AFile, TempFile, True);
    SetLength(FPreviewTempFiles, Length(FPreviewTempFiles) + 1);
    FPreviewTempFiles[High(FPreviewTempFiles)] := TempFile;
    Result := TempFile;
  except
    on E: Exception do Log('预览媒体复制失败：' + E.Message);
  end;
end;

function TMainForm.PreviewMediaUrl(const AFile, AId: string): string;
var LocalFile: string;
begin
  LocalFile := PreviewMediaFile(AFile);
  if (AId <> '') and (LocalFile <> '') then
    FMediaPreviewFiles.AddOrSetValue(AId, LocalFile);
  Result := PathToUrl(LocalFile);
end;

procedure TMainForm.MediaComboChange(Sender: TObject);
var R: TGuiResource; MediaFile: string;
begin
  if (FMediaPlayer = nil) or (FMediaCombo.ItemIndex < 0) then Exit;
  R := TGuiResource(FMediaCombo.Items.Objects[FMediaCombo.ItemIndex]);
  if R = nil then Exit;
  try
    FMediaPlayer.Close;
    if FMediaPreviewFiles.TryGetValue(R.Id, MediaFile) and
       (MediaFile <> '') and TFile.Exists(MediaFile) then
    begin
      FMediaPlayer.FileName := MediaFile;
      FMediaPlayer.Open;
      SetStatus('已载入媒体：' + ExtractFileName(MediaFile));
    end;
  except
    on E: Exception do
    begin
      Log('媒体载入失败：' + E.Message);
      SetStatus('媒体载入失败：' + E.Message);
    end;
  end;
end;

procedure TMainForm.RefreshMediaPanel;
var
  C: TGuiChapter;
  P, ClosePos, Q: Integer;
  Token, Key, Id: string;
  R: TGuiResource;
  I, SelIndex: Integer;
  MediaFile: string;
begin
  if (FMediaPanel = nil) or (FMediaCombo = nil) or (FMediaPlayer = nil) then Exit;
  try FMediaPlayer.Close; except end;
  FMediaCombo.Items.Clear;
  SelIndex := -1;
  C := CurrentChapter;
  if C <> nil then
  begin
    P := 1;
    while True do
    begin
      P := PosEx('{{', C.Content, P);
      if P = 0 then Break;
      ClosePos := PosEx('}}', C.Content, P + 2);
      if ClosePos = 0 then Break;
      Token := Copy(C.Content, P + 2, ClosePos - P - 2);
      Q := Pos(':', Token);
      if Q > 0 then
      begin
        Key := LowerCase(Trim(Copy(Token, 1, Q - 1)));
        Id := Trim(Copy(Token, Q + 1, MaxInt));
        if (Key = 'audio') or (Key = 'video') then
          for I := 0 to FResources.Count - 1 do
          begin
            R := FResources[I];
            if (R.Id <> Id) or (R.Kind <> akAudio) and (R.Kind <> akVideo) then Continue;
            if not TFile.Exists(R.SourceFile) then Continue;
            if Key = 'audio' then
              FMediaCombo.Items.AddObject('♪ 音频  ' + R.Id + ' - ' +
                ExtractFileName(R.SourceFile), R)
            else
              FMediaCombo.Items.AddObject('▶ 视频  ' + R.Id + ' - ' +
                ExtractFileName(R.SourceFile), R);
            Break;
          end;
      end;
      P := ClosePos + 2;
    end;
  end;

  FMediaPanel.Visible := FMediaCombo.Items.Count > 0;
  if not FMediaPanel.Visible then Exit;
  FMediaCombo.ItemIndex := 0;
  MediaComboChange(FMediaCombo);
end;

function TMainForm.FixImageSources(const AHtml: string): string;
var
  P, TagEnd, SrcPos, Q, VStart, VEnd: Integer;
  Src, LocalFile, NewSrc, Quote, AppDir, TestPath: string;
begin
  Result := AHtml;
  AppDir := ExtractFilePath(ParamStr(0));
  P := 1;
  while True do
  begin
    P := FindTextCI(Result, '<img', P);
    if P = 0 then Break;
    TagEnd := PosEx('>', Result, P);
    if TagEnd = 0 then Break;
    SrcPos := FindTextCI(Result, 'src=', P);
    if (SrcPos = 0) or (SrcPos > TagEnd) then
    begin
      P := TagEnd + 1;
      Continue;
    end;
    Q := SrcPos + 4;
    while (Q <= TagEnd) and (Result[Q] <= ' ') do Inc(Q);
    if Q > TagEnd then begin P := TagEnd + 1; Continue; end;
    Quote := '';
    if (Result[Q] = '"') or (Result[Q] = '''') then
    begin
      Quote := Result[Q];
      Inc(Q);
    end;
    VStart := Q;
    if Quote <> '' then
    begin
      VEnd := PosEx(Quote, Result, VStart);
      if (VEnd = 0) or (VEnd > TagEnd) then begin P := TagEnd + 1; Continue; end;
    end
    else
    begin
      VEnd := VStart;
      while (VEnd <= TagEnd) and (Result[VEnd] > ' ') do Inc(VEnd);
    end;
    Src := Trim(Copy(Result, VStart, VEnd - VStart));
    if (Copy(LowerCase(Src), 1, 5) = 'data:') or
       (Copy(LowerCase(Src), 1, 7) = 'http://') or
       (Copy(LowerCase(Src), 1, 8) = 'https://') or (Src = '') then
    begin
      P := VEnd + 1;
      Continue;
    end;
    LocalFile := '';
    if Copy(LowerCase(Src), 1, 8) = 'file:///' then
      LocalFile := DecodePercentUrl(Copy(Src, 9, MaxInt))
    else if Copy(LowerCase(Src), 1, 7) = 'file://' then
      LocalFile := DecodePercentUrl(Copy(Src, 8, MaxInt))
    else
      LocalFile := DecodePercentUrl(Src);
    LocalFile := StringReplace(LocalFile, '/', '\', [rfReplaceAll]);

    if (LocalFile <> '') and (not TFile.Exists(LocalFile)) then
    begin
      if TPath.IsPathRooted(LocalFile) then
        LocalFile := ''
      else
      begin
        TestPath := TPath.GetFullPath(TPath.Combine(AppDir, LocalFile));
        if TFile.Exists(TestPath) then LocalFile := TestPath
        else
        begin
          TestPath := TPath.GetFullPath(TPath.Combine(AppDir, '..', LocalFile));
          if TFile.Exists(TestPath) then LocalFile := TestPath
          else LocalFile := '';
        end;
      end;
    end;

    if (LocalFile <> '') and TFile.Exists(LocalFile) then
    begin
      NewSrc := PreviewImageUrl(LocalFile);
      Delete(Result, VStart, VEnd - VStart);
      Insert(NewSrc, Result, VStart);
      P := VStart + Length(NewSrc);
    end
    else
      P := VEnd + 1;
  end;
end;

function TMainForm.GetPreviewSource: string;
var
  P: PAnsiChar;
  Bytes: TBytes;
  I, L: Integer;
  Raw: AnsiString;
begin
  Result := '';
  if (FPreviewBrowser <> nil) and (FPreviewBrowser.mainwkeview <> nil) and
     Assigned(wkeGetSource) then
  begin
    P := wkeGetSource(FPreviewBrowser.mainwkeview);
    if P <> nil then
    begin
      Raw := P;
      L := Length(Raw);
      SetLength(Bytes, L);
      for I := 1 to L do Bytes[I - 1] := Byte(Raw[I]);
      try
        Result := TEncoding.UTF8.GetString(Bytes);
      except
        Result := '';
      end;
    end;
  end;
  if Result = '' then
    try
      Result := FPreviewBrowser.GetSource;
    except
      Result := '';
    end;
  if Result = '' then Result := FLastPreviewHtml;
end;

procedure TMainForm.ShowPreviewSource;
var F: TViewSourceForm;
    C: TGuiChapter;
begin
  Application.ProcessMessages;
  F := TViewSourceForm.Create(Self);
  try
    C := CurrentChapter;
    if C <> nil then F.Caption := 'HTML 源代码 — ' + C.Title;
    F.SetSource(GetPreviewSource);
    F.ShowModal;
  finally
    F.Free;
  end;
end;

procedure TMainForm.BtnViewSourceClick(Sender: TObject);
begin
  ShowPreviewSource;
  if FPageControl.PageCount > 0 then
    FPageControl.ActivePageIndex := 3;
end;

function TMainForm.BuildPreviewHtml(const ABody: string): string;
var
  P, Q, ClosePos: Integer;
  Token, Key, Id, Replacement, Src: string;
  I: Integer;
  R: TGuiResource;
  C: TGuiChapter;
  SB: TStringBuilder;
begin
  Result := ABody;

  // 将双花括号占位符转换为指向本地源文件的可预览 HTML
  P := Pos('{{', Result);
  while P > 0 do
  begin
    ClosePos := PosEx('}}', Result, P + 2);
    if ClosePos = 0 then Break;
    Token := Copy(Result, P + 2, ClosePos - P - 2);
    Q := Pos(':', Token);
    Replacement := '';
    if Q > 0 then
    begin
      Key := LowerCase(Trim(Copy(Token, 1, Q - 1)));
      Id := Trim(Copy(Token, Q + 1, MaxInt));
      for I := 0 to FResources.Count - 1 do
      begin
        R := FResources[I];
        if R.Id <> Id then Continue;
        if (Key = 'audio') and (R.Kind = akAudio) then
        begin
          Src := PreviewMediaUrl(R.SourceFile, R.Id);
          Replacement := '<div class="epub-media">' +
            '<audio controls style="width:100%" src="' + Src + '">浏览器不支持音频</audio>' +
            '<div class="epub-media-hint">当前 Wke 内核没有 HTML5 媒体解码后端，' +
            '请在预览页下方“媒体播放”栏使用系统解码器播放。</div></div>'
        end
        else if (Key = 'video') and (R.Kind = akVideo) then
        begin
          Src := PreviewMediaUrl(R.SourceFile, R.Id);
          Replacement := '<div class="epub-media">' +
            '<video controls style="max-width:100%" src="' + Src + '">浏览器不支持视频</video>' +
            '<div class="epub-media-hint">当前 Wke 内核没有 HTML5 媒体解码后端，' +
            '请在预览页下方“媒体播放”栏使用系统解码器播放。</div></div>'
        end
        else if (Key = 'image') and (R.Kind = akImage) then
        begin
          Src := PreviewImageUrl(R.SourceFile);
          Replacement := '<img style="max-width:100%" src="' + Src + '" alt="' + Id + '"/>';
        end;
        Break;
      end;
      if (Key = 'link') and (Replacement = '') then
        for I := 0 to FChapters.Count - 1 do
        begin
          C := FChapters[I];
          if C.Id = Id then
          begin
            Replacement := '<a href="#" onclick="return false">' + C.Title + '</a>';
            Break;
          end;
        end;
    end;
    if Replacement <> '' then
    begin
      Delete(Result, P, ClosePos - P + 2);
      Insert(Replacement, Result, P);
      P := P + Length(Replacement);
    end
    else
      P := ClosePos + 2;
    P := Pos('{{', Result, P);
  end;

  { 兼容章节正文中手写的 img src：中文路径 / 相对路径统一转换为可显示的 URL }
  Result := FixImageSources(Result);

  { 包装成完整 HTML 文档，注入样式与所有 CSS 资源 }
  SB := TStringBuilder.Create;
  try
    SB.Append('<!DOCTYPE html>').Append(sLineBreak);
    SB.Append('<html><head><meta charset="utf-8">').Append(sLineBreak);
    SB.Append('<title>EPUB 章节预览</title>').Append(sLineBreak);
    SB.Append('<style>body{font-family:"宋体",serif;font-size:16px;line-height:1.7;').Append(
      'max-width:900px;margin:24px auto;padding:0 16px;color:#222;}' +
      '.epub-media{margin:12px 0;padding:8px;border:1px dashed #bbb;background:#fafafa;}' +
      '.epub-media-hint{color:#888;font-size:13px;margin-top:6px;}</style>').Append(sLineBreak);
    for I := 0 to FResources.Count - 1 do
      if FResources[I].Kind = akStyle then
        SB.Append('<link rel="stylesheet" href="' +
          PreviewCssUrl(FResources[I].SourceFile) + '"/>').Append(sLineBreak);
    SB.Append('</head><body>').Append(sLineBreak);
    SB.Append(Result).Append(sLineBreak);
    SB.Append('</body></html>');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TMainForm.RefreshPreview;
var
  C: TGuiChapter;
  Html, Title: string;
begin
  if FPreviewBrowser = nil then Exit;
  { 先关闭播放器，再清理它正在使用的临时媒体副本 }
  if Assigned(FMediaPlayer) then
    try FMediaPlayer.Close; except end;
  CleanupPreviewTempFiles;
  C := CurrentChapter;
  if C = nil then
  begin
    Html := BuildPreviewHtml('<p style="color:#999">（未选择章节）</p>');
    Title := '（未选择章节）';
  end
  else
  begin
    Html := BuildPreviewHtml(C.Content);
    Title := C.Title;
  end;

  { 同步媒体播放栏：Wke 无法播放 HTML5 媒体，改由系统解码器提供播放控制 }
  RefreshMediaPanel;

  try
    { Wke 直接加载 UTF-16 HTML 字符串；中文路径的图片已内嵌为 data URI }
    FPreviewBrowser.LoadHtml(Html);
    FLastPreviewHtml := Html;
    SetStatus('预览已刷新（Wke 内核）：' + Title);
  except
    on E: Exception do
      Log('预览失败：' + E.Message);
  end;
end;

procedure TMainForm.BtnRefreshPreviewClick(Sender: TObject);
begin
  RefreshPreview;
  if FPageControl.PageCount > 0 then
    FPageControl.ActivePageIndex := 3;  // 切换到 HTML 预览页
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
      FSynEditor.Enabled := False;
      FCboLevel.Enabled := False;
      FCboParent.Enabled := False;
      FCboSmil.Enabled := False;
      FChkInToc.Enabled := False;
      FChkCoverChapter.Enabled := False;
      FSynEditor.Text := '';
      Exit;
    end;

    FEdChapterTitle.Enabled := True;
    FEdChapterFile.Enabled := True;
    FSynEditor.Enabled := True;
    FCboLevel.Enabled := True;
    FCboParent.Enabled := True;
    FCboSmil.Enabled := True;
    FChkInToc.Enabled := True;
    FChkCoverChapter.Enabled := True;

    FEdChapterTitle.Text := C.Title;
    FEdChapterFile.Text := C.FileName;
    FSynEditor.Text := C.Content;
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
  C.Content := FSynEditor.Text;
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
  RefreshPreview;  // 切换章节时同步更新预览
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

function TMainForm.LanguageCodeOf(const AText: string): string;
var
  L, R: Integer;
begin
  Result := Trim(AText);
  L := LastDelimiter('(', Result);
  R := LastDelimiter(')', Result);
  if (L > 0) and (R > L) then
    Result := Trim(Copy(Result, L + 1, R - L - 1));
end;

function TMainForm.CreatePickerDialog(const ACaption: string;
  AItems: TStrings): TForm;
var
  Dlg: TForm;
  BtnPanel: TPanel;
  LB: TListBox;
  BtnOk, BtnCancel: TButton;
begin
  Dlg := TForm.Create(nil);
  Result := Dlg;
  Dlg.Caption := ACaption;
  Dlg.Width := 460;
  { Height 含标题栏与边框；留足客户区高度，底部按钮才不会被裁切 }
  Dlg.Height := 380;
  Dlg.Position := poOwnerFormCenter;
  Dlg.BorderStyle := bsDialog;

  { 底部按钮区用独立面板 + alBottom，按客户区高度自动贴合窗体底边 }
  BtnPanel := TPanel.Create(Dlg);
  BtnPanel.Parent := Dlg;
  BtnPanel.Name := 'PickerBtnPanel';
  BtnPanel.Align := alBottom;
  BtnPanel.Height := 48;
  BtnPanel.BevelOuter := bvNone;

  LB := TListBox.Create(Dlg);
  LB.Parent := Dlg;
  LB.Name := 'PickerList';
  LB.Align := alClient;
  if AItems <> nil then
    LB.Items.Assign(AItems);
  if LB.Items.Count > 0 then
    LB.ItemIndex := 0;

  BtnOk := TButton.Create(BtnPanel);
  BtnOk.Parent := BtnPanel;
  BtnOk.Name := 'PickerBtnOk';
  BtnOk.Caption := '确定';
  BtnOk.ModalResult := mrOk;
  BtnOk.Left := Dlg.Width - 166;
  BtnOk.Top := 9;
  BtnOk.Width := 74;
  BtnOk.Height := 30;
  BtnOk.Default := True;
  BtnOk.Anchors := [akRight, akTop];

  BtnCancel := TButton.Create(BtnPanel);
  BtnCancel.Parent := BtnPanel;
  BtnCancel.Name := 'PickerBtnCancel';
  BtnCancel.Caption := '取消';
  BtnCancel.ModalResult := mrCancel;
  BtnCancel.Left := Dlg.Width - 86;
  BtnCancel.Top := 9;
  BtnCancel.Width := 74;
  BtnCancel.Height := 30;
  BtnCancel.Cancel := True;
  BtnCancel.Anchors := [akRight, akTop];
end;

function TMainForm.SelectFromList(const ACaption: string; const AItems: TStrings;
  out AIndex: Integer): Boolean;
var
  Dlg: TForm;
  LB: TListBox;
begin
  Result := False;
  AIndex := -1;
  Dlg := CreatePickerDialog(ACaption, AItems);
  try
    LB := Dlg.FindChildControl('PickerList') as TListBox;
    if (Dlg.ShowModal = mrOk) and (LB <> nil) and (LB.ItemIndex >= 0) then
    begin
      AIndex := LB.ItemIndex;
      Result := True;
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TMainForm.ProposalExecute(Kind: SynCompletionType; Sender: TObject;
  var CurrentInput: UnicodeString; var x, y: Integer; var CanExecute: Boolean);
var
  I, CharPos: Integer;
  Line: UnicodeString;
  R: TGuiResource;
  C: TGuiChapter;
  DisplayText, InsertText: UnicodeString;
begin
  { 每次弹出时根据当前项目资源动态重建候选列表 }
  FResourceProposal.ClearList;
  SetLength(FProposalItemFiles, 0);

  for I := 0 to FResources.Count - 1 do
  begin
    R := FResources[I];
    case R.Kind of
      akAudio:
        begin
          DisplayText := '♪ 音频  ' + R.Id + ' - ' + ExtractFileName(R.SourceFile);
          InsertText := '{{audio:' + R.Id + '}}';
          AppendProposalItem(DisplayText, InsertText, '');
        end;
      akVideo:
        begin
          DisplayText := '▶ 视频  ' + R.Id + ' - ' + ExtractFileName(R.SourceFile);
          InsertText := '{{video:' + R.Id + '}}';
          AppendProposalItem(DisplayText, InsertText, '');
        end;
      akImage:
        begin
          DisplayText := '▣ 图片  ' + R.Id + ' - ' + ExtractFileName(R.SourceFile);
          InsertText := '{{image:' + R.Id + '}}';
          AppendProposalItem(DisplayText, InsertText, R.SourceFile);
        end;
      akStyle:
        AppendProposalItem('# CSS  ' + R.Id + '（发布时自动链接，无需占位符）', '', '');
      akFont:
        AppendProposalItem('A 字体  ' + R.Id + '（发布时自动链接，无需占位符）', '', '');
      akSmil:
        AppendProposalItem('♫ SMIL  ' + R.Id + '（在章节页关联，无需占位符）', '', '');
    end;
  end;

  for I := 0 to FChapters.Count - 1 do
  begin
    C := FChapters[I];
    DisplayText := '↗ 章节  ' + C.Id + ' - ' + C.Title;
    InsertText := '{{link:' + C.Id + '}}';
    AppendProposalItem(DisplayText, InsertText, '');
  end;

  AppendProposalItem('{ 输入普通左花括号 {', '{', '');
  AppendProposalItem('} 输入普通右花括号 }', '}', '');

  { 清空输入，避免刚输入的 { 过滤掉所有候选 }
  CurrentInput := '';
  CanExecute := FResourceProposal.ItemList.Count > 0;

  { 将替换区间起点定位到光标前刚输入的 {，使插入后不残留多余括号 }
  if Assigned(FSynEditor) then
  begin
    Line := FSynEditor.LineText;
    CharPos := FSynEditor.CaretX - 1;
    if (CharPos >= 1) and (CharPos <= Length(Line)) and (Line[CharPos] = '{') then
      FResourceProposal.CompletionStart := CharPos;
  end;
end;

procedure TMainForm.AppendProposalItem(const ADisplay, AInsert, AImageFile: string);
var
  N: Integer;
begin
  FResourceProposal.AddItem(ADisplay, AInsert);
  { 与 ItemList 同步记录候选项对应的图片路径（非图片项为空串） }
  N := Length(FProposalItemFiles);
  SetLength(FProposalItemFiles, N + 1);
  FProposalItemFiles[N] := AImageFile;
end;

procedure TMainForm.ProposalChange(Sender: TObject; AIndex: Integer);
var
  ImgFile: string;
begin
  { AIndex 由 SynEdit 以物理索引回调（见 LogicalToPhysicalIndex），
    与 FProposalItemFiles 的添加顺序一致，可直接索引 }
  ImgFile := '';
  if (AIndex >= 0) and (AIndex < Length(FProposalItemFiles)) then
    ImgFile := FProposalItemFiles[AIndex];

  if (ImgFile = '') or (not TFile.Exists(ImgFile)) then
  begin
    HideImagePreview;
    Exit;
  end;

  ShowImagePreview(ImgFile, FResourceProposal.Width);
end;

procedure TMainForm.ShowImagePreview(const AFile: string; AMaxWidth: Integer);
var
  Pic: TPicture;
  W, H, MaxH, NewW, NewH, ListW: Integer;
begin
  if not Assigned(FImagePreviewPanel) then Exit;
  if (AFile = '') or (not TFile.Exists(AFile)) then
  begin
    HideImagePreview;
    Exit;
  end;

  Pic := TPicture.Create;
  try
    try
      Pic.LoadFromFile(AFile);
    except
      HideImagePreview;
      Exit;
    end;
    W := Pic.Width;
    H := Pic.Height;
    if (W <= 0) or (H <= 0) then
    begin
      HideImagePreview;
      Exit;
    end;

    { 宽度上限：补全候选列表框宽度，不超过它；同时留出边距 }
    ListW := AMaxWidth;
    if ListW < 80 then ListW := 260;
    if ListW > FResourceProposal.Width then ListW := FResourceProposal.Width;
    if ListW > 480 then ListW := 480;
    MaxH := 300;

    NewW := W;
    NewH := H;
    if NewW > ListW then
    begin
      NewH := Round(H * (ListW / W));
      NewW := ListW;
    end;
    if NewH > MaxH then
    begin
      NewW := Round(NewW * (MaxH / NewH));
      NewH := MaxH;
    end;
    if NewW < 1 then NewW := 1;
    if NewH < 1 then NewH := 1;

    FPreviewImage.Picture.Assign(Pic);
    FPreviewImageLabel.Caption := ' 图片预览  ' + ExtractFileName(AFile) +
      '  (' + IntToStr(W) + '×' + IntToStr(H) + ')';

    { 面板宽度严格不超过候选列表框宽度（含 2px 边框 + 左右各 2px Padding） }
    FImagePreviewPanel.Width := NewW + 8;
    if FImagePreviewPanel.Width > FResourceProposal.Width then
      FImagePreviewPanel.Width := FResourceProposal.Width;
    FImagePreviewPanel.Height := NewH + FPreviewImageLabel.Height + 8;

    { 按偏好把面板紧贴到补全候选列表框的左侧/顶部/右侧/底部 }
    PlacePreviewPanel(FImagePreviewPanel.Width, FImagePreviewPanel.Height);

    FImagePreviewPanel.Visible := True;
    FImagePreviewPanel.BringToFront;
  finally
    Pic.Free;
  end;
end;

procedure TMainForm.PlacePreviewPanel(APanelW, APanelH: Integer);
var
  ProposalForm: TForm;
  Host: TWinControl;
  Scr, HostOrigin: TPoint;
  ListL, ListT, ListW, ListH: Integer;
  Gap: Integer;
begin
  if not Assigned(FImagePreviewPanel) then Exit;
  Host := FImagePreviewPanel.Parent;
  if Host = nil then Exit;

  Gap := 6;
  ListL := 12;
  ListT := 120;
  ListW := FResourceProposal.Width;
  ListH := 240;

  { 补全窗体是独立弹出窗口，其 Left/Top 为屏幕坐标；
    转换为面板父容器（章节编辑页）的客户区坐标，实现真正"紧贴" }
  if Assigned(FResourceProposal) and (FResourceProposal.Form <> nil) then
  begin
    ProposalForm := TForm(FResourceProposal.Form);
    if ProposalForm.HandleAllocated and Host.HandleAllocated then
    begin
      HostOrigin := Host.ClientToScreen(Point(0, 0));
      ListL := ProposalForm.Left - HostOrigin.X;
      ListT := ProposalForm.Top - HostOrigin.Y;
      ListW := ProposalForm.Width;
      ListH := ProposalForm.Height;
    end;
  end;

  { 默认停靠到列表框左侧、顶部对齐；按偏好调整 }
  case FPreviewDock of
    pdLeft:
      begin
        FImagePreviewPanel.Left := ListL - APanelW - Gap;
        FImagePreviewPanel.Top := ListT;
      end;
    pdTop:
      begin
        FImagePreviewPanel.Left := ListL;
        FImagePreviewPanel.Top := ListT - APanelH - Gap;
      end;
    pdRight:
      begin
        FImagePreviewPanel.Left := ListL + ListW + Gap;
        FImagePreviewPanel.Top := ListT;
      end;
    pdBottom:
      begin
        FImagePreviewPanel.Left := ListL;
        FImagePreviewPanel.Top := ListT + ListH + Gap;
      end;
    pdAuto:
      begin
        { 自动：优先左侧，空间不足则顶部，再不足则右侧/底部 }
        if ListL - APanelW - Gap >= 0 then
        begin
          FImagePreviewPanel.Left := ListL - APanelW - Gap;
          FImagePreviewPanel.Top := ListT;
        end
        else if ListT - APanelH - Gap >= 0 then
        begin
          FImagePreviewPanel.Left := ListL;
          FImagePreviewPanel.Top := ListT - APanelH - Gap;
        end
        else if ListL + ListW + Gap + APanelW <= Host.ClientWidth then
        begin
          FImagePreviewPanel.Left := ListL + ListW + Gap;
          FImagePreviewPanel.Top := ListT;
        end
        else
        begin
          FImagePreviewPanel.Left := ListL;
          FImagePreviewPanel.Top := ListT + ListH + Gap;
        end;
      end;
  end;

  { 确保面板完整留在父容器可见范围内 }
  if FImagePreviewPanel.Left < 0 then FImagePreviewPanel.Left := 0;
  if FImagePreviewPanel.Top < 0 then FImagePreviewPanel.Top := 0;
  if FImagePreviewPanel.Left + APanelW > Host.ClientWidth then
    FImagePreviewPanel.Left := Host.ClientWidth - APanelW;
  if FImagePreviewPanel.Top + APanelH > Host.ClientHeight then
    FImagePreviewPanel.Top := Host.ClientHeight - APanelH;
  if FImagePreviewPanel.Left < 0 then FImagePreviewPanel.Left := 0;
  if FImagePreviewPanel.Top < 0 then FImagePreviewPanel.Top := 0;
end;

function TMainForm.PreviewDockToStr(ADock: TPreviewDock): string;
begin
  case ADock of
    pdLeft:   Result := 'left';
    pdTop:    Result := 'top';
    pdRight:  Result := 'right';
    pdBottom: Result := 'bottom';
  else
    Result := 'auto';
  end;
end;

function TMainForm.StrToPreviewDock(const S: string): TPreviewDock;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if L = 'left' then Result := pdLeft
  else if L = 'top' then Result := pdTop
  else if L = 'right' then Result := pdRight
  else if L = 'bottom' then Result := pdBottom
  else Result := pdAuto;
end;

procedure TMainForm.LoadPreviewDock;
var
  Ini: TIniFile;
  Path: string;
  Saved: string;
begin
  FPreviewDock := pdAuto;
  if Assigned(FCboPreviewDock) then
    FCboPreviewDock.ItemIndex := Ord(pdAuto);

  Path := EditorIniPath;
  if not TFile.Exists(Path) then Exit;
  Ini := TIniFile.Create(Path);
  try
    Saved := Ini.ReadString('Preview', 'Dock', 'auto');
    FPreviewDock := StrToPreviewDock(Saved);
    if Assigned(FCboPreviewDock) then
      FCboPreviewDock.ItemIndex := Ord(FPreviewDock);
  except
    on E: Exception do
      FPreviewDock := pdAuto;
  end;
  Ini.Free;
end;

procedure TMainForm.SavePreviewDock;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(EditorIniPath);
  try
    Ini.WriteString('Preview', 'Dock', PreviewDockToStr(FPreviewDock));
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.CboPreviewDockChange(Sender: TObject);
begin
  if (FCboPreviewDock = nil) or (FCboPreviewDock.ItemIndex < 0) then Exit;
  FPreviewDock := TPreviewDock(FCboPreviewDock.ItemIndex);
  SavePreviewDock;
  { 若当前预览可见，按新位置立即重新停靠 }
  if Assigned(FImagePreviewPanel) and FImagePreviewPanel.Visible then
    PlacePreviewPanel(FImagePreviewPanel.Width, FImagePreviewPanel.Height);
  SetStatus('图片预览位置：' + FCboPreviewDock.Items[FCboPreviewDock.ItemIndex]);
end;

procedure TMainForm.HideImagePreview;
begin
  if Assigned(FImagePreviewPanel) then
    FImagePreviewPanel.Visible := False;
end;

procedure TMainForm.ProposalClose(Sender: TObject);
begin
  HideImagePreview;
end;

procedure TMainForm.ProposalAfterCodeCompletion(Sender: TObject;
  const Value: UnicodeString; Shift: TShiftState; Index: Integer;
  EndToken: WideChar);
begin
  Log('已通过智能提示插入占位符：' + string(Value));
  HideImagePreview;
end;

procedure TMainForm.InsertToken(const AToken: string);
var
  P: Integer;
begin
  P := FSynEditor.SelStart;
  FSynEditor.SelText := AToken;
  FSynEditor.SelStart := P + Length(AToken);
  FSynEditor.SelEnd := FSynEditor.SelStart;
  FSynEditor.SetFocus;
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
    G.Metadata.Language := LanguageCodeOf(FCboLanguage.Text);
    if Trim(FEdIdentifier.Text) <> '' then
      G.Metadata.Identifier := Trim(FEdIdentifier.Text);
    G.Metadata.Publisher := FEdPublisher.Text;
    G.Metadata.Description := FMemoDescription.Text;
    G.Metadata.Subject := FEdSubject.Text;
    G.Metadata.Date := FormatDateTime('yyyy-mm-dd', FEdDate.Date);
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
  FCboLanguage.ItemIndex := 0;
  FEdIdentifier.Text := '';
  FEdPublisher.Text := 'EpubBuilder GUI';
  FEdSubject.Text := 'EPUB 3.0，音视频';
  FEdDate.Date := Now;
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
  DummyInput: UnicodeString;
  DummyX, DummyY: Integer;
  CanExec: Boolean;
  I, HasAudio, HasVideo, HasChapter: Integer;
  ListText, PreviewHtml, SourceHtml, ZhHtml, ZhDir, ZhImg: string;
  BuildOk, PreviewOk, WkeOk: Boolean;
  SourceOk, SourceFormOk, ChinesePathOk, MediaPanelOk, DatePickerOk: Boolean;
  TagHiOk, TagOk2, TagOk3, TagOk4, TagOk5: Boolean;
  TagP: TPoint;
  TagLineText: string;
  TagCharPos, TagLineNo: Integer;
  TagBufPos: TBufferCoord;
  TagSrc: string;
  PanelPreviewOk, ImageMapOk, DockOk: Boolean;
  ImgIndex, ImgPanelWidth, ListWidth, LeftX, RightX: Integer;
  ImgFile: string;
  FmtBtnOk, FmtOk, FmtStructureOk, FmtIdempotentOk, FmtQuoteOk: Boolean;
  FmtSrc, FmtOut, FmtOut2: string;
  ChFmtOk, ChSyncOk, ChUndoOk, ChBtnOk: Boolean;
  ChTagHiOk, ChTagOk2, ChTagOk3, ChTagOk4: Boolean;
  PickerDlg: TForm;
  PickerPanel: TPanel;
  PickerBtn: TButton;
  PickerOk: Boolean;
  LangOk: Boolean;
  PhOk, PhClassOk, PhAttrsOk, PhScanOk, PhWholeOk, PhHtmlOk: Boolean;
  PhKindsOk, PhIniOk, PhBtnOk, PhAttrCaseOk: Boolean;
  PhDlgOk: Boolean;
  PhExpOk, PhContOk: Boolean;
  PhKindCount, PhMatchCount, PhGuard: Integer;
  PhPrevPos, PhPrevLen: Integer;
  PhLineNo, PhCharIdx: Integer;
  PhTest, PhTok, PhTok2, PhIniPath, PhAttrName: string;
  PhLine, PhExpLine, PhRebuilt: UnicodeString;
  PhOldColor: TColor;
  PhKind: TEpubPlaceholderKind;
  PhAttr: TSynHighlighterAttributes;
  PHS: TSynEpubPlaceholderSyn;
  PhBtn: TButton;
  PSD: TPlaceholderStyleDialog;
  ChapterSrc, ChapterOut, OldChapterContent: string;
  R: TGuiResource;
  VSF: TViewSourceForm;
begin
  F := TMainForm.Create(nil);
  Lines := TStringList.Create;
  FmtOk := False;
  FmtQuoteOk := False;
  FmtBtnOk := False;
  FmtStructureOk := False;
  FmtIdempotentOk := False;
  TagHiOk := False;
  ChFmtOk := False;
  ChSyncOk := False;
  ChUndoOk := False;
  ChBtnOk := False;
  ChTagHiOk := False;
  ChTagOk2 := False;
  ChTagOk3 := False;
  ChTagOk4 := False;
  PickerOk := False;
  LangOk := False;
  PhOk := False;
  PhClassOk := False;
  PhAttrsOk := False;
  PhScanOk := False;
  PhWholeOk := True;
  PhHtmlOk := True;
  PhKindsOk := False;
  PhIniOk := False;
  PhBtnOk := False;
  PhAttrCaseOk := False;
  PhDlgOk := False;
  PhExpOk := False;
  PhContOk := False;
  PhKindCount := 0;
  PhMatchCount := 0;
  try
    OutPath := TPath.Combine(TPath.GetTempPath, 'EpuBuilderGuiSelfTest.epub');
    LogPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'selftest.log');
    BuildOk := F.BuildEpub(OutPath);

    { 验证 SynEdit 集成与智能提示候选构建 }
    Lines.Add('=== SynEdit integration checks ===');
    Lines.Add(' Highlighter=' + F.FHtmlHighlighter.ClassName +
      ' (expected TSynEpubPlaceholderSyn, a TSynHTMLSyn descendant)');
    Lines.Add(' Proposal.Editor=' + F.FResourceProposal.Editor.ClassName +
      ' (expected TSynEdit)');
    Lines.Add(' TriggerChars=' + string(F.FResourceProposal.TriggerChars));

    { 占位符分类高亮器：验证每个占位符整体成 token、按类型套用独立 attribute，
      HTML 标签仍使用原 TSynHTMLSyn 属性，样式可经 ini 往返 }
    Lines.Add('=== Placeholder highlighter checks ===');
    PhClassOk := (F.FPlaceholderHighlighter <> nil) and
      (F.FPlaceholderHighlighter is TSynEpubPlaceholderSyn) and
      (F.FHtmlHighlighter = F.FPlaceholderHighlighter) and
      (F.FHtmlHighlighter is TSynHTMLSyn) and
      (F.FSynEditor.Highlighter = F.FPlaceholderHighlighter);
    if F.FPlaceholderHighlighter <> nil then
    begin
      PHS := F.FPlaceholderHighlighter;
      PhAttrsOk := (PHS.ImageAttri <> nil) and (PHS.AudioAttri <> nil) and
        (PHS.VideoAttri <> nil) and (PHS.LinkAttri <> nil) and
        (PHS.UnknownAttri <> nil) and
        (PHS.ImageAttri <> PHS.AudioAttri) and
        (PHS.VideoAttri <> PHS.LinkAttri) and
        (PHS.ImageAttri.Foreground <> PHS.AudioAttri.Foreground) and
        (PHS.ImageAttri.Background <> clNone) and
        (PHS.LinkAttri.Background <> clNone) and
        (fsBold in PHS.ImageAttri.Style) and
        (fsUnderline in PHS.LinkAttri.Style) and
        (fsItalic in PHS.UnknownAttri.Style);

      PhTest := '<p>{{image:R001}} {{audio:R002}} {{video:R003}} ' +
        '{{link:C006}} {{custom:X}}</p>';
      PHS.SetLine(PhTest, 1);
      PhGuard := 0;
      while (not PHS.GetEol) and (PhGuard < 300) do
      begin
        PhTok := string(PHS.GetToken);
        PhAttr := PHS.GetTokenAttribute;
        if PhAttr = nil then PhAttrName := '<nil>' else PhAttrName := PhAttr.Name;
        if Copy(PhTok, 1, 2) = '{{' then
        begin
          Inc(PhKindCount);
          PhWholeOk := PhWholeOk and
            (Copy(PhTok, Length(PhTok) - 1, 2) = '}}');
          PhKind := TSynEpubPlaceholderSyn.PlaceholderKindOf(PhTok);
          if PhAttr = PHS.AttributeFor(PhKind) then Inc(PhMatchCount);
          Lines.Add('  token=' + PhTok + ' kind=' + IntToStr(Ord(PhKind)) +
            ' attr=' + PhAttrName);
        end
        else
          PhHtmlOk := PhHtmlOk and (PhAttr <> PHS.ImageAttri) and
            (PhAttr <> PHS.AudioAttri) and (PhAttr <> PHS.VideoAttri) and
            (PhAttr <> PHS.LinkAttri) and (PhAttr <> PHS.UnknownAttri);
        PHS.Next;
        Inc(PhGuard);
      end;
      PhScanOk := (PhKindCount = 5) and (PhMatchCount = 5) and PhWholeOk and
        (PhGuard < 300);
      PhKindsOk :=
        (TSynEpubPlaceholderSyn.PlaceholderKindOf('{{image:R001}}') = pkImage) and
        (TSynEpubPlaceholderSyn.PlaceholderKindOf('{{audio:R002}}') = pkAudio) and
        (TSynEpubPlaceholderSyn.PlaceholderKindOf('{{video:R003}}') = pkVideo) and
        (TSynEpubPlaceholderSyn.PlaceholderKindOf('{{link:C006}}') = pkLink) and
        (TSynEpubPlaceholderSyn.PlaceholderKindOf('{{custom:X}}') = pkUnknown);
      PHS.ResetRange;

      { 属性值内的占位符同样整体识别，且不破坏 HTML 引号状态 }
      PHS.SetLine('<img src="{{image:R001}}" alt="x">', 1);
      PhGuard := 0;
      while (not PHS.GetEol) and (PhGuard < 200) do
      begin
        PhTok := string(PHS.GetToken);
        if Copy(PhTok, 1, 2) = '{{' then
          PhAttrCaseOk := (Copy(PhTok, Length(PhTok) - 1, 2) = '}}') and
            (PHS.GetTokenAttribute = PHS.ImageAttri);
        PHS.Next;
        Inc(PhGuard);
      end;
      PhAttrCaseOk := PhAttrCaseOk and (PhGuard < 200);
      PHS.ResetRange;

      PhIniPath := TPath.Combine(TPath.GetTempPath, 'EpubPlaceholderStyleTest.ini');
      PhOldColor := PHS.ImageAttri.Foreground;
      PHS.ImageAttri.Foreground := MakeEpubColor($12, $34, $56);
      PHS.SaveStyleSettings(PhIniPath);
      PHS.ImageAttri.Foreground := clBlack;
      PHS.LoadStyleSettings(PhIniPath);
      PhIniOk := (ColorToRGB(PHS.ImageAttri.Foreground) =
        ColorToRGB(MakeEpubColor($12, $34, $56)));
      PHS.ImageAttri.Foreground := PhOldColor;
      System.SysUtils.DeleteFile(PhIniPath);

      { 宽字符展开路径回归：完整模拟截图中三行混排（h1 标题 / 纯中文段落 /
        中文+占位符段落）。SynEdit 绘制时调用 SetLineExpandedAtWideGlyphs，
        逐行按「非 ASCII 字符前插 FillerChar」构造展开串，要求：
        (a) 展开 token 无缝拼回展开串；(b) 位置连续；(c) 占位符样式只落在
        占位符本身，绝不串到相邻中文或 HTML 标签上。 }
      PhExpOk := True;
      PhContOk := True;
      for PhLineNo := 0 to 2 do
      begin
        case PhLineNo of
          0: PhLine := '<h1>第一章:</h1>';
          1: PhLine := '<p>本书由可视化构建器生成，</p>';
        else
          PhLine := '<p>跳转到 {{link:C006}}</p>';
        end;
        PhExpLine := '';
        for PhCharIdx := 1 to Length(PhLine) do
        begin
          if Ord(PhLine[PhCharIdx]) > 127 then
            PhExpLine := PhExpLine + WideChar($E000);
          PhExpLine := PhExpLine + PhLine[PhCharIdx];
        end;
        PHS.SetLineExpandedAtWideGlyphs(PhLine, PhExpLine, PhLineNo);
        PhGuard := 0;
        PhRebuilt := '';
        PhPrevPos := 0;
        PhPrevLen := 0;
        while (not PHS.GetEol) and (PhGuard < 300) do
        begin
          PhTok2 := string(PHS.GetExpandedToken);
          if PhGuard > 0 then
            PhContOk := PhContOk and
              (PHS.GetExpandedTokenPos = PhPrevPos + PhPrevLen);
          PhPrevPos := PHS.GetExpandedTokenPos;
          PhPrevLen := Length(PhTok2);
          PhRebuilt := PhRebuilt + PhTok2;
          PhAttr := PHS.GetTokenAttribute;
          if (Pos('{{', PhTok2) > 0) and (Pos('}}', PhTok2) > 0) then
            PhExpOk := PhExpOk and (PhAttr = PHS.LinkAttri)
          else
            PhExpOk := PhExpOk and (PhAttr <> PHS.LinkAttri) and
              (PhAttr <> PHS.ImageAttri) and (PhAttr <> PHS.AudioAttri) and
              (PhAttr <> PHS.VideoAttri) and (PhAttr <> PHS.UnknownAttri);
          PHS.Next;
          Inc(PhGuard);
        end;
        while (Length(PhRebuilt) > 0) and (PhRebuilt[Length(PhRebuilt)] = #0) do
          SetLength(PhRebuilt, Length(PhRebuilt) - 1);
        PhExpOk := PhExpOk and (PhRebuilt = PhExpLine) and (PhGuard < 300);
      end;
      PHS.ResetRange;
      Lines.Add(' Wide-char 3-line mix: rebuilt+no-color-bleed=' +
        BoolToStr(PhExpOk, True) + ' continuous=' + BoolToStr(PhContOk, True));

      Lines.Add(' ClassOk=' + BoolToStr(PhClassOk, True) +
        ' AttrsOk=' + BoolToStr(PhAttrsOk, True) +
        ' tokens=' + IntToStr(PhKindCount) +
        ' matched=' + IntToStr(PhMatchCount) +
        ' paired=' + BoolToStr(PhWholeOk, True) +
        ' htmlIntact=' + BoolToStr(PhHtmlOk, True) +
        ' kindsOk=' + BoolToStr(PhKindsOk, True) +
        ' iniOk=' + BoolToStr(PhIniOk, True) +
        ' attrCaseOk=' + BoolToStr(PhAttrCaseOk, True));
    end;

    PhBtn := nil;
    for I := 0 to F.ComponentCount - 1 do
      if (F.Components[I] is TButton) and
         (TButton(F.Components[I]).Caption = '占位符样式') then
        PhBtn := TButton(F.Components[I]);
    PhBtnOk := PhBtn <> nil;

    { 样式设置对话框可无异常构建（自检不弹出交互界面） }
    PSD := TPlaceholderStyleDialog.CreateNew(nil);
    try
      try
        PSD.Init(F.FPlaceholderHighlighter);
        PhDlgOk := (PSD.FCboKind <> nil) and (PSD.FCboKind.Items.Count = 5) and
          (PSD.FPreview <> nil) and (PSD.FChkBold <> nil) and
          (PSD.FChkItalic <> nil) and (PSD.FChkUnderline <> nil) and
          (PSD.FChkStrike <> nil) and (PSD.FBtnFore <> nil) and
          (PSD.FBtnBack <> nil);
        Lines.Add(' Style dialog controls ok=' + BoolToStr(PhDlgOk, True));
      except
        on E: Exception do
          Lines.Add(' Style dialog FAILED: ' + E.Message);
      end;
    finally
      PSD.Free;
    end;

    PhOk := PhClassOk and PhAttrsOk and PhScanOk and PhHtmlOk and
      PhKindsOk and PhIniOk and PhBtnOk and PhAttrCaseOk and PhDlgOk and PhExpOk;
    Lines.Add(' Style button=' + BoolToStr(PhBtnOk, True) +
      ' overall=' + BoolToStr(PhOk, True));

    DummyInput := '{';
    DummyX := 0;
    DummyY := 0;
    CanExec := False;
    F.ProposalExecute(ctCode, F, DummyInput, DummyX, DummyY, CanExec);
    HasAudio := 0;
    HasVideo := 0;
    HasChapter := 0;
    ListText := '';
    for I := 0 to F.FResourceProposal.ItemList.Count - 1 do
    begin
      ListText := ListText + '    [' + string(F.FResourceProposal.ItemList[I]) + ']' + sLineBreak;
      if Pos('audio:', string(F.FResourceProposal.InsertList[I])) > 0 then Inc(HasAudio);
      if Pos('video:', string(F.FResourceProposal.InsertList[I])) > 0 then Inc(HasVideo);
      if Pos('link:',  string(F.FResourceProposal.InsertList[I])) > 0 then Inc(HasChapter);
    end;
    Lines.Add(' Proposal items=' + F.FResourceProposal.ItemList.Count.ToString +
      ' CanExecute=' + BoolToStr(CanExec, True));
    Lines.Add(' audio candidates=' + HasAudio.ToString +
      ' video candidates=' + HasVideo.ToString +
      ' chapter-link candidates=' + HasChapter.ToString);
    Lines.Add(ListText);

    { 验证出版日期使用 Delphi 自带 TDateTimePicker 日历下拉控件 }
    Lines.Add('=== Publication date checks ===');
    DatePickerOk := (F.FEdDate is TDateTimePicker) and
      (F.FEdDate.Kind = dtkDate) and
      (FormatDateTime('yyyy-mm-dd', F.FEdDate.Date) = FormatDateTime('yyyy-mm-dd', Now));
    Lines.Add(' Control=' + F.FEdDate.ClassName +
      ' (expected TDateTimePicker)');
    Lines.Add(' Date=' + FormatDateTime('yyyy-mm-dd', F.FEdDate.Date) +
      ' Format=' + F.FEdDate.Format +
      ' ok=' + BoolToStr(DatePickerOk, True));

    { 验证语言改为下拉框：多项可选，且能从显示名正确提取 BCP 47 代码 }
    Lines.Add('=== Language dropdown checks ===');
    LangOk := (F.FCboLanguage is TComboBox) and
      (F.FCboLanguage.Items.Count >= 10) and
      (F.FCboLanguage.Style = csDropDown) and
      (F.LanguageCodeOf(F.FCboLanguage.Items[0]) = 'zh-CN') and
      (F.LanguageCodeOf('英语 (en-US)') = 'en-US') and
      (F.LanguageCodeOf('custom-tag') = 'custom-tag');
    Lines.Add(' Control=' + F.FCboLanguage.ClassName +
      ' items=' + F.FCboLanguage.Items.Count.ToString +
      ' item0=' + F.FCboLanguage.Items[0] +
      ' code=' + F.LanguageCodeOf(F.FCboLanguage.Items[0]) +
      ' ok=' + BoolToStr(LangOk, True));

    { 验证字体配置（默认宋体 12，若用户自定义则为 ini 中的值） }
    Lines.Add('=== Font settings checks ===');
    Lines.Add(' Font.Name=' + F.FSynEditor.Font.Name +
      ' Size=' + F.FSynEditor.Font.Size.ToString +
      ' Color=$' + IntToHex(ColorToRGB(F.FSynEditor.Font.Color), 6));

    { 验证章节管理页的“格式化排版”按钮：复用同一格式化器并写回章节编辑器 }
    Lines.Add('=== Chapter format checks ===');
    ChBtnOk := False;
    ChFmtOk := False;
    ChSyncOk := False;
    ChUndoOk := False;
    if F.FChapterList.Items.Count > 0 then
    try
      F.FChapterList.ItemIndex := 0;
      F.ChapterListClick(F.FChapterList);
      OldChapterContent := F.FChapters[0].Content;
      ChapterSrc := '<div><h1>标题</h1><p>正文 <span>强调</span></p></div>';
      F.FSynEditor.Text := ChapterSrc;
      F.FSynEditor.ClearUndo;
      ChBtnOk := True;
      F.BtnFormatChapterClick(nil);
      ChapterOut := F.FSynEditor.Text;
      ChFmtOk := (Pos('  <h1>标题</h1>', ChapterOut) > 0) and
        (Pos('  <p>正文 <span>强调</span></p>', ChapterOut) > 0) and
        (Pos('<div>', ChapterOut) > 0);
      ChSyncOk := (F.FChapters[0].Content = ChapterOut);
      Lines.Add(' Button exists=' + BoolToStr(ChBtnOk, True) +
        ' formatted=' + BoolToStr(ChFmtOk, True) +
        ' chapter synced=' + BoolToStr(ChSyncOk, True));
      Lines.Add('--- formatted chapter ---');
      Lines.AddStrings(F.FSynEditor.Lines);
      Lines.Add('------------------------');
      F.FSynEditor.Undo;
      ChUndoOk := (F.FSynEditor.Text = ChapterSrc);
      Lines.Add(' Undo restored=' + BoolToStr(ChUndoOk, True));
      { 还原章节内容，避免影响后续构建与 Python 校验 }
      F.FSynEditor.Text := OldChapterContent;
      F.FSynEditor.ClearUndo;
    except
      on E: Exception do
        Lines.Add(' Chapter format FAILED: ' + E.ClassName + ': ' + E.Message);
    end
    else
      Lines.Add(' No chapter available for format check');

    { 验证资源选择弹窗：底部按钮完全落在窗体客户区内，不被边框裁切 }
    Lines.Add('=== Resource picker dialog checks ===');
    PickerDlg := F.CreatePickerDialog('选择要插入的图片', nil);
    try
      PickerOk := False;
      try
        PickerPanel := PickerDlg.FindChildControl('PickerBtnPanel') as TPanel;
      PickerBtn := nil;
      if PickerPanel <> nil then
        PickerBtn := PickerPanel.FindChildControl('PickerBtnOk') as TButton;
      PickerOk := (PickerDlg.Height >= 360) and (PickerBtn <> nil) and
        (PickerPanel <> nil) and (PickerPanel.Align = alBottom) and
        (PickerBtn.Top >= 0) and
        (PickerBtn.Top + PickerBtn.Height <= PickerPanel.Height) and
        (PickerPanel.FindChildControl('PickerBtnCancel') <> nil) and
        (PickerDlg.FindChildControl('PickerList') is TListBox);
      if (PickerBtn <> nil) and (PickerPanel <> nil) then
      begin
        Lines.Add(' Dlg.Height=' + PickerDlg.Height.ToString +
          ' ClientHeight=' + PickerDlg.ClientHeight.ToString +
          ' btnPanel.Height=' + PickerPanel.Height.ToString +
          ' btn.Top=' + PickerBtn.Top.ToString +
          ' btn.Bottom=' + (PickerBtn.Top + PickerBtn.Height).ToString);
      end
      else
        Lines.Add(' Picker controls not found (panel=' +
          BoolToStr(PickerPanel <> nil, True) + ' btn=' +
          BoolToStr(PickerBtn <> nil, True) + ')');
      Lines.Add(' Button fully inside bottom panel=' + BoolToStr(PickerOk, True));
      except
        on E: Exception do
          Lines.Add(' Picker dialog FAILED: ' + E.ClassName + ': ' + E.Message);
      end;
    finally
      PickerDlg.Free;
    end;

    { 验证章节编辑器的成对标签整体高亮：与查看源代码窗体共用 SelectPairedTagInEditor }
    Lines.Add('=== Chapter tag highlight checks ===');
    if F.FChapterList.Items.Count > 0 then
    try
      F.FChapterList.ItemIndex := 0;
      F.ChapterListClick(F.FChapterList);
      OldChapterContent := F.FChapters[0].Content;
      ChTagHiOk := (ColorToRGB(F.FSynEditor.SelectedColor.Background) = $00F0F0F0) and
        Assigned(F.FSynEditor.OnMouseDown) and Assigned(F.FSynEditor.OnMouseUp);

      TagSrc := '<div id="outer">' + sLineBreak +
        '  <span>测试</span>' + sLineBreak + '</div>';
      F.FSynEditor.Text := TagSrc;
      F.FSynEditor.ClearUndo;
      TagBufPos.Line := 1;
      TagBufPos.Char := Pos('div', F.FSynEditor.Lines[0]);
      TagP := F.FSynEditor.RowColumnToPixels(
        F.FSynEditor.BufferToDisplayPos(TagBufPos));
      F.SelectTagInChapterEditor(TagP);
      TagLineText := F.FSynEditor.SelText;
      ChTagOk2 := (Pos('<div', TagLineText) = 1) and
        (Pos('<span>测试</span>', TagLineText) > 0) and
        (Pos('</div>', TagLineText) > 0);

      TagBufPos.Line := 3;
      TagBufPos.Char := Pos('</div>', F.FSynEditor.Lines[2]) + 2;
      TagP := F.FSynEditor.RowColumnToPixels(
        F.FSynEditor.BufferToDisplayPos(TagBufPos));
      F.SelectTagInChapterEditor(TagP);
      ChTagOk3 := (Pos('<div', F.FSynEditor.SelText) = 1) and
        (Pos('</div>', F.FSynEditor.SelText) > 0);

      F.FSynEditor.Text := '<div><div>内层</div></div>';
      F.FSynEditor.ClearUndo;
      TagBufPos.Line := 1;
      TagBufPos.Char := 2;
      TagP := F.FSynEditor.RowColumnToPixels(
        F.FSynEditor.BufferToDisplayPos(TagBufPos));
      F.SelectTagInChapterEditor(TagP);
      ChTagOk4 := (F.FSynEditor.SelText = '<div><div>内层</div></div>');

      F.FSynEditor.Text := OldChapterContent;
      F.FSynEditor.ClearUndo;
      Lines.Add(' SelectedColor + mouse handlers=' + BoolToStr(ChTagHiOk, True));
      Lines.Add(' Click open <div> -> pair block=' + BoolToStr(ChTagOk2, True));
      Lines.Add(' Click close </div> -> pair block=' + BoolToStr(ChTagOk3, True));
      Lines.Add(' Nested same-name <div> -> outer pair=' + BoolToStr(ChTagOk4, True));
    except
      on E: Exception do
        Lines.Add(' Chapter tag highlight FAILED: ' + E.ClassName + ': ' + E.Message);
    end;

    { 切换到含音视频的章节，确保预览与媒体播放栏基于同一章节 }
    if F.FChapterList.Items.Count > 2 then
    begin
      F.FChapterList.ItemIndex := 2;
      F.ChapterListClick(F.FChapterList);
    end;

    { 验证 HTML 预览：占位符应转换为音视频标签与本地文件 URL }
    Lines.Add('=== HTML preview checks ===');
    PreviewHtml := F.BuildPreviewHtml(F.FChapters[2].Content);
    PreviewOk := (Pos('<audio', PreviewHtml) > 0) and
                 (Pos('<video', PreviewHtml) > 0) and
                 (Pos('file:///', PreviewHtml) > 0) and
                 (Pos('<!DOCTYPE html>', PreviewHtml) > 0) and
                 (Pos('epub-media-hint', PreviewHtml) > 0);
    Lines.Add(' Preview has audio tag=' + BoolToStr(Pos('<audio', PreviewHtml) > 0, True) +
      ' video tag=' + BoolToStr(Pos('<video', PreviewHtml) > 0, True) +
      ' file url=' + BoolToStr(Pos('file:///', PreviewHtml) > 0, True));
    Lines.Add(' Preview html length=' + PreviewHtml.Length.ToString);

    { 验证 Wke 浏览器替换：类型应为 TWkeWebBrowser，且可加载 HTML 不报错 }
    Lines.Add('=== Wke browser checks ===');
    WkeOk := F.FPreviewBrowser is TWkeWebBrowser;
    Lines.Add(' Preview browser=' + F.FPreviewBrowser.ClassName +
      ' (expected TWkeWebBrowser)');
    try
      F.FPreviewBrowser.LoadHtml('<!DOCTYPE html><html><body><h1>Wke OK</h1></body></html>');
      Lines.Add(' Wke.LoadHtml=OK');
    except
      on E: Exception do
      begin
        WkeOk := False;
        Lines.Add(' Wke.LoadHtml FAILED: ' + E.Message);
      end;
    end;
    Lines.Add(' Wke.dll=' + TPath.Combine(ExtractFilePath(ParamStr(0)), 'Wke.dll') +
      ' exists=' + BoolToStr(TFile.Exists(TPath.Combine(ExtractFilePath(ParamStr(0)), 'Wke.dll')), True));

    { 验证“查看源代码”：应能取到 FPreviewBrowser 当前 HTML，且查看窗体可显示中文 }
    Lines.Add('=== View source checks ===');
    SourceFormOk := False;
    try
      F.RefreshPreview;
      SourceHtml := F.GetPreviewSource;
      SourceOk := (SourceHtml <> '') and
        (Pos('<html', LowerCase(SourceHtml)) > 0);
      Lines.Add(' Source length=' + SourceHtml.Length.ToString +
        ' has html tag=' + BoolToStr(Pos('<html', LowerCase(SourceHtml)) > 0, True));
      VSF := TViewSourceForm.Create(F);
      try
        VSF.SetSource(SourceHtml + sLineBreak + '<!-- 中文源代码测试 -->');
        Lines.Add(' Source editor=' + VSF.FSourceEditor.ClassName +
          ' (expected TSynEdit)' +
          ' highlighter=' + VSF.FSourceHighlighter.ClassName +
          ' (expected TSynHTMLSyn)' +
          ' readonly=' + BoolToStr(VSF.FSourceEditor.ReadOnly, True));
        SourceFormOk := (Pos('中文源代码测试', VSF.FSourceEditor.Lines.Text) > 0) and
          (VSF.FSourceEditor is TSynEdit) and
          (VSF.FSourceHighlighter is TSynHTMLSyn) and
          (VSF.FSourceEditor.Highlighter = VSF.FSourceHighlighter) and
          VSF.FSourceEditor.ReadOnly;

        { 成对标签高亮：选区底色浅灰；点开始/结束标签应选中整对标签块 }
        TagHiOk := (ColorToRGB(VSF.FSourceEditor.SelectedColor.Background) = $00F0F0F0);
        Lines.Add(' SelectedColor.Background=$' +
          IntToHex(ColorToRGB(VSF.FSourceEditor.SelectedColor.Background), 6) +
          ' (expected 00F0F0F0 light gray)');

        { 多行样本：<div> 内含 <span>，点 div 应覆盖整对 div（含内层） }
        TagSrc := '<div id="outer">' + sLineBreak +
          '  <span>测试</span>' + sLineBreak + '</div>';
        VSF.SetSource(TagSrc);
        TagBufPos.Line := 1;
        TagBufPos.Char := Pos('div', VSF.FSourceEditor.Lines[0]);  { 点开始标签 <div> }
        TagP := VSF.FSourceEditor.RowColumnToPixels(
          VSF.FSourceEditor.BufferToDisplayPos(TagBufPos));
        VSF.SelectTagAt(TagP);
        TagLineText := VSF.FSourceEditor.SelText;
        TagOk2 := (Pos('<div', TagLineText) = 1) and
                  (Pos('<span>测试</span>', TagLineText) > 0) and
                  (Pos('</div>', TagLineText) > 0);
        Lines.Add(' Click open <div> -> pair block=' + BoolToStr(TagOk2, True) +
          ' len=' + TagLineText.Length.ToString);

        { 点结束标签 </div> 也应选中整对 div }
        TagBufPos.Line := 3;
        TagBufPos.Char := Pos('</div>', VSF.FSourceEditor.Lines[2]) + 2;
        TagP := VSF.FSourceEditor.RowColumnToPixels(
          VSF.FSourceEditor.BufferToDisplayPos(TagBufPos));
        VSF.SelectTagAt(TagP);
        TagOk3 := (Pos('<div', VSF.FSourceEditor.SelText) = 1) and
                  (Pos('</div>', VSF.FSourceEditor.SelText) > 0);
        Lines.Add(' Click close </div> -> pair block=' + BoolToStr(TagOk3, True));

        { 点内层 <span> 应只选中 span 这一对，不应扩大到外层 div }
        TagBufPos.Line := 2;
        TagBufPos.Char := Pos('span', VSF.FSourceEditor.Lines[1]) + 1;
        TagP := VSF.FSourceEditor.RowColumnToPixels(
          VSF.FSourceEditor.BufferToDisplayPos(TagBufPos));
        VSF.SelectTagAt(TagP);
        TagLineText := VSF.FSourceEditor.SelText;
        TagOk4 := (Pos('<span>', TagLineText) = 1) and
                  (Pos('</span>', TagLineText) > 0) and
                  (Pos('<div', TagLineText) = 0);
        Lines.Add(' Click <span> -> own pair only=' + BoolToStr(TagOk4, True) +
          ' [' + TagLineText + ']');

        { 同名嵌套：点外层 <div> 应靠深度计数匹配到最外层的 </div> }
        VSF.SetSource('<div><div>内层</div></div>');
        TagBufPos.Line := 1;
        TagBufPos.Char := 2;
        TagP := VSF.FSourceEditor.RowColumnToPixels(
          VSF.FSourceEditor.BufferToDisplayPos(TagBufPos));
        VSF.SelectTagAt(TagP);
        TagLineText := VSF.FSourceEditor.SelText;
        TagOk5 := (TagLineText = '<div><div>内层</div></div>');
        Lines.Add(' Nested same-name <div> -> full outer pair=' +
          BoolToStr(TagOk5, True) + ' [' + TagLineText + ']');

        TagHiOk := TagHiOk and TagOk2 and TagOk3 and TagOk4 and TagOk5;

        { 格式化排版按钮：块级标签分层缩进，短小的内联内容保持同一行 }
        FmtBtnOk := (VSF.FFormatButton <> nil) and
          (VSF.FFormatButton.Caption = '格式化排版');
        FmtSrc := '<!DOCTYPE html><html><head><meta charset="utf-8">' +
          '<title>标题</title></head><body><div id="a">' +
          '<p>文本 <span>内联</span></p><p>第二行</p></div></body></html>';
        VSF.SetSource(FmtSrc);
        FmtOk := VSF.FormatSource;
        FmtOut := VSF.FSourceEditor.Lines.Text;
        FmtStructureOk := (Pos('<!DOCTYPE html>', FmtOut) > 0) and
          (Pos('  <head>', FmtOut) > 0) and
          (Pos('    <meta charset="utf-8">', FmtOut) > 0) and
          (Pos('    <div id="a">', FmtOut) > 0) and
          (Pos('      <p>文本 <span>内联</span></p>', FmtOut) > 0) and
          (Pos('</html>', FmtOut) > 0) and VSF.IsFormatted and
          (VSF.FFormatButton.Caption = '恢复原始');
        Lines.Add(' Format button exists=' + BoolToStr(FmtBtnOk, True) +
          ' formatted=' + BoolToStr(FmtStructureOk, True) +
          ' lines=' + VSF.FSourceEditor.Lines.Count.ToString);
        Lines.Add('--- formatted source ---');
        Lines.AddStrings(VSF.FSourceEditor.Lines);
        Lines.Add('-----------------------');

        { 再次格式化应保持不变（幂等） }
        FmtOut2 := FormatHtmlSource(FmtOut);
        FmtIdempotentOk := (FmtOut2 = FmtOut);
        Lines.Add(' Format idempotent=' + BoolToStr(FmtIdempotentOk, True));

        { 引号内的 '>' 不应被误判为标签结束；script 内容保持原样 }
        FmtSrc := '<div data-x="a>b"><p title="1 > 0">OK</p></div>';
        VSF.SetSource(FmtSrc);
        FmtOk := FmtOk and VSF.FormatSource;
        FmtOut2 := VSF.FSourceEditor.Lines.Text;
        FmtQuoteOk := (Pos('data-x="a>b"', FmtOut2) > 0) and
                      (Pos('title="1 > 0">OK</p>', FmtOut2) > 0);
        FmtSrc := '<html><body><script>if (a < b) { x="</div>"; }</script></body></html>';
        VSF.SetSource(FmtSrc);
        FmtOk := FmtOk and VSF.FormatSource;
        FmtOut2 := VSF.FSourceEditor.Lines.Text;
        FmtQuoteOk := FmtQuoteOk and (Pos('if (a < b)', FmtOut2) > 0) and
          (Pos('</script>', FmtOut2) > 0) and (Pos('</body>', FmtOut2) > 0);
        Lines.Add(' Attribute/script preserved=' + BoolToStr(FmtQuoteOk, True));

        { 再次点击按钮应恢复原始源码 }
        FmtOk := FmtOk and VSF.RestoreSource and (not VSF.IsFormatted) and
          (VSF.FSourceEditor.Lines.Text = FmtSrc) and
          (VSF.FFormatButton.Caption = '格式化排版');
        Lines.Add(' Restore original=' + BoolToStr(FmtOk, True));
      finally
        VSF.Free;
      end;
      Lines.Add(' Source dialog shows Chinese=' + BoolToStr(SourceFormOk, True));
    except
      on E: Exception do
      begin
        SourceOk := False;
        Lines.Add(' View source FAILED: ' + E.Message);
      end;
    end;

    { 验证中文路径图片：占位符与手写 img src 均应转换为 data URI }
    Lines.Add('=== Chinese path image checks ===');
    ChinesePathOk := False;
    ZhDir := TPath.Combine(TPath.GetTempPath, 'epub中文路径预览测试');
    ZhImg := TPath.Combine(ZhDir, '封面图片.png');
    try
      TDirectory.CreateDirectory(ZhDir);
      if F.FResources.Count > 0 then
      begin
        TFile.Copy(F.FResources[0].SourceFile, ZhImg, True);
        R := TGuiResource.Create(F.NewId('R'));
        try
          R.Kind := akImage;
          R.SourceFile := ZhImg;
          R.ArchiveName := 'zh_cover.png';
          R.MimeType := 'image/png';
          F.FResources.Add(R);
          ZhHtml := F.BuildPreviewHtml('<p>中文路径图片测试</p>{{image:' + R.Id + '}}');
          ChinesePathOk := Pos('data:image/', ZhHtml) > 0;
          Lines.Add(' Placeholder with Chinese path -> data URI=' +
            BoolToStr(ChinesePathOk, True));
          ZhHtml := F.BuildPreviewHtml('<img src="' + ZhImg + '">');
          ChinesePathOk := ChinesePathOk and (Pos('data:image/', ZhHtml) > 0);
          Lines.Add(' Raw img src with Chinese path -> data URI=' +
            BoolToStr(Pos('data:image/', ZhHtml) > 0, True));
        finally
          F.FResources.Remove(R);  // TObjectList 拥有对象，Remove 会自动释放
        end;
      end;
    except
      on E: Exception do
        Lines.Add(' Chinese path test FAILED: ' + E.Message);
    end;
    try
      if TDirectory.Exists(ZhDir) then TDirectory.Delete(ZhDir, True);
    except
    end;

    { 验证媒体播放栏：Wke 无 HTML5 媒体后端，系统解码器播放栏应可用 }
    Lines.Add('=== Media playback checks ===');
    MediaPanelOk := F.FMediaPanel.Visible and
      (F.FMediaCombo.Items.Count > 0) and (F.FMediaPlayer.FileName <> '') and
      TFile.Exists(F.FMediaPlayer.FileName);
    Lines.Add(' Media items=' + F.FMediaCombo.Items.Count.ToString +
      ' player=' + ExtractFileName(F.FMediaPlayer.FileName) +
      ' visible=' + BoolToStr(F.FMediaPanel.Visible, True));

    { 验证图片预览面板：候选映射 → 选中图片项 → TPanel 中显示且宽度不超列表框 }
    Lines.Add('=== Image preview panel checks ===');
    ImgIndex := -1;
    for I := 0 to High(F.FProposalItemFiles) do
      if (F.FProposalItemFiles[I] <> '') and TFile.Exists(F.FProposalItemFiles[I]) then
      begin
        ImgIndex := I;
        Break;
      end;
    ImageMapOk := ImgIndex >= 0;
    PanelPreviewOk := False;
    if ImageMapOk then
    begin
      ImgFile := F.FProposalItemFiles[ImgIndex];
      ListWidth := F.FResourceProposal.Width;
      try
        F.HideImagePreview;
        { 通过 OnChange 回调选中图片候选：普通 TPanel 的 Visible 切换
          不会触发窗体 CMShowingChanged，故请求会同步生效、无重入异常 }
        F.ProposalChange(F.FResourceProposal, ImgIndex);
        ImgPanelWidth := F.FImagePreviewPanel.Width;
        PanelPreviewOk := F.FImagePreviewPanel.Visible and
          (F.FPreviewImage.Picture.Width > 0) and
          (ImgPanelWidth <= ListWidth);

        { 预览宽度不应超过补全候选列表框宽度 }
        Lines.Add(' Image candidate[' + ImgIndex.ToString + ']=' + ExtractFileName(ImgFile));
        Lines.Add(' Panel width=' + ImgPanelWidth.ToString +
          ' list width=' + ListWidth.ToString +
          ' visible=' + BoolToStr(F.FImagePreviewPanel.Visible, True));

        { 停靠位置验证：切换偏好后面板应贴合列表框不同方位，且始终在父容器内 }
        F.FPreviewDock := pdLeft;
        F.PlacePreviewPanel(ImgPanelWidth, F.FImagePreviewPanel.Height);
        LeftX := F.FImagePreviewPanel.Left;
        F.FPreviewDock := pdRight;
        F.PlacePreviewPanel(ImgPanelWidth, F.FImagePreviewPanel.Height);
        RightX := F.FImagePreviewPanel.Left;
        F.FPreviewDock := pdAuto;
        F.PlacePreviewPanel(ImgPanelWidth, F.FImagePreviewPanel.Height);
        DockOk := (RightX > LeftX) and
          (F.FImagePreviewPanel.Left >= 0) and
          (F.FImagePreviewPanel.Top >= 0) and
          (F.FImagePreviewPanel.Left + ImgPanelWidth <=
            F.FImagePreviewPanel.Parent.ClientWidth);
        Lines.Add(' Dock left x=' + LeftX.ToString + ' right x=' + RightX.ToString +
          ' ok=' + BoolToStr(DockOk, True));
        PanelPreviewOk := PanelPreviewOk and DockOk;

        { 选中非图片候选（映射为空）时预览应隐藏 }
        F.HideImagePreview;
        PanelPreviewOk := PanelPreviewOk and (not F.FImagePreviewPanel.Visible);
        { 关闭补全时也应隐藏 }
        F.ProposalClose(F.FResourceProposal);
        PanelPreviewOk := PanelPreviewOk and (not F.FImagePreviewPanel.Visible);
      except
        on E: Exception do
        begin
          PanelPreviewOk := False;
          Lines.Add(' Image preview panel FAILED: ' + E.Message);
        end;
      end;
    end;

    if BuildOk and (F.FHtmlHighlighter is TSynHTMLSyn) and
       (F.FResourceProposal.Editor = F.FSynEditor) and
       (F.FResourceProposal.TriggerChars = '{') and
       (HasAudio > 0) and (HasVideo > 0) and (HasChapter > 0) and
       (F.FSynEditor.Font.Name <> '') and (F.FSynEditor.Font.Size > 0) and
       PreviewOk and WkeOk and SourceOk and SourceFormOk and ChinesePathOk and
       MediaPanelOk and ImageMapOk and PanelPreviewOk and DatePickerOk and TagHiOk and
       FmtBtnOk and FmtOk and FmtStructureOk and FmtIdempotentOk and FmtQuoteOk and
       ChBtnOk and ChFmtOk and ChSyncOk and ChUndoOk and
       ChTagHiOk and ChTagOk2 and ChTagOk3 and ChTagOk4 and PickerOk and
       LangOk and PhOk then
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
