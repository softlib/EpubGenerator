unit EpubPlaceholderSyn;

{==============================================================================
  EpubPlaceholderSyn.pas —— 章节编辑器专用高亮器

  直接继承工作区 SynEdit 提供的 TSynHTMLSyn（其祖先即
  SynEditHighlighter.pas 中的 TSynCustomHighlighter），因此：
    1) 完整保留 TSynHTMLSyn 的 XHTML 标签 / 属性 / 实体 / 注释着色；
    2) 额外把 image / audio / video / link 四类双花括号占位符
       以及未知占位符各自识别为「一个完整 token」，分别套用独立的
       TSynHighlighterAttributes —— 前景色、背景色、字体样式（粗体 / 斜体 /
       下划线 / 删除线）均可单独设置；
    3) 样式可通过 EditorSettings.ini 的 [Placeholder.*] 段持久化。

  实现要点：重写 SetLine 预扫描本行占位符区间；重写 Next 在父类词法产出
  跨界 token 时截断到占位符起点，下一次 Next 由占位符分支整体接管。
  由于 Run / FTokenPos 与父类状态机共享，且占位符视作不改变 HTML range 的
  普通文本，跨行注释、引号内属性等 HTML 状态仍然连续正确。
==============================================================================}

interface

uses
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  System.IniFiles,
  System.UITypes,
  Vcl.Graphics,
  SynUnicode,
  SynEditHighlighter,
  SynHighlighterHtml;

const
  { 占位符 token 的 GetTokenKind 值域，避开 HTML 的 tkTokenKind }
  SYN_EPUB_KIND_BASE = 1000;

type
  TEpubPlaceholderKind = (pkImage, pkAudio, pkVideo, pkLink, pkUnknown);

  TEpubPlaceholderRec = record
    StartPos: Integer;   { 0-based，指向占位符起始的左花括号 }
    EndPos: Integer;     { 0-based，开区间，指向结束花括号之后 }
    Kind: TEpubPlaceholderKind;
  end;
  TEpubPlaceholderArray = array of TEpubPlaceholderRec;

  TSynEpubPlaceholderSyn = class(TSynHTMLSyn)
  private
    FImageAttri: TSynHighlighterAttributes;
    FAudioAttri: TSynHighlighterAttributes;
    FVideoAttri: TSynHighlighterAttributes;
    FLinkAttri: TSynHighlighterAttributes;
    FUnknownAttri: TSynHighlighterAttributes;
    FPlaceholders: TEpubPlaceholderArray;
    FPhIdx: Integer;
    FCurAttri: TSynHighlighterAttributes;
    FCurKind: Integer;
    procedure ScanPlaceholders(const ALine: UnicodeString);
    procedure AdvanceExpanded(AFromExpRun, ACharDelta: Integer);
    procedure ApplyIniToAttribute(AIni: TIniFile; AAttri: TSynHighlighterAttributes);
    procedure WriteAttributeToIni(AIni: TIniFile; AAttri: TSynHighlighterAttributes);
  public
    constructor Create(AOwner: TComponent); override;
    class function PlaceholderKindOf(const AText: string): TEpubPlaceholderKind;
    procedure SetLine(const Value: UnicodeString; LineNumber: Integer); override;
    procedure SetLineExpandedAtWideGlyphs(const Line, ExpandedLine: UnicodeString;
      LineNumber: Integer); override;
    { 以下 4 个虚方法在 TSynHTMLSyn 中为 public，保持可见性一致 }
    function GetEol: Boolean; override;
    function GetTokenAttribute: TSynHighlighterAttributes; override;
    function GetTokenKind: Integer; override;
    procedure Next; override;
    function AttributeFor(AKind: TEpubPlaceholderKind): TSynHighlighterAttributes;
    procedure ResetStyleDefaults;
    procedure LoadStyleSettings(const AIniFile: string);
    procedure SaveStyleSettings(const AIniFile: string);
    property ImageAttri: TSynHighlighterAttributes read FImageAttri;
    property AudioAttri: TSynHighlighterAttributes read FAudioAttri;
    property VideoAttri: TSynHighlighterAttributes read FVideoAttri;
    property LinkAttri: TSynHighlighterAttributes read FLinkAttri;
    property UnknownAttri: TSynHighlighterAttributes read FUnknownAttri;
  end;

function MakeEpubColor(R, G, B: Byte): TColor;

implementation

function MakeEpubColor(R, G, B: Byte): TColor;
begin
  Result := TColor(R or (G shl 8) or (B shl 16));  { $00BBGGRR }
end;

{ TSynEpubPlaceholderSyn }

constructor TSynEpubPlaceholderSyn.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);   { 父类已创建 9 个 HTML 属性并挂好变更事件 }

  FImageAttri := TSynHighlighterAttributes.Create('placeholder_image', '图片占位符');
  AddAttribute(FImageAttri);
  FAudioAttri := TSynHighlighterAttributes.Create('placeholder_audio', '音频占位符');
  AddAttribute(FAudioAttri);
  FVideoAttri := TSynHighlighterAttributes.Create('placeholder_video', '视频占位符');
  AddAttribute(FVideoAttri);
  FLinkAttri := TSynHighlighterAttributes.Create('placeholder_link', '章节链接占位符');
  AddAttribute(FLinkAttri);
  FUnknownAttri := TSynHighlighterAttributes.Create('placeholder_unknown', '未知占位符');
  AddAttribute(FUnknownAttri);

  ResetStyleDefaults;
  { 新增属性也需要挂上重绘通知，并把当前值登记为默认值 }
  SetAttributesOnChange(DefHighlightChange);
  SetLength(FPlaceholders, 0);
  FPhIdx := 0;
  FCurAttri := nil;
  FCurKind := 0;
end;

procedure TSynEpubPlaceholderSyn.ResetStyleDefaults;
begin
  { 图片：青绿；音频：紫；视频：砖红；链接：蓝并带下划线；未知：灰底斜体警示 }
  FImageAttri.Foreground := MakeEpubColor($00, $70, $70);
  FImageAttri.Background := MakeEpubColor($E6, $F7, $F4);
  FImageAttri.Style := [fsBold];

  FAudioAttri.Foreground := MakeEpubColor($80, $20, $A0);
  FAudioAttri.Background := MakeEpubColor($F6, $EA, $FA);
  FAudioAttri.Style := [fsBold];

  FVideoAttri.Foreground := MakeEpubColor($B0, $30, $20);
  FVideoAttri.Background := MakeEpubColor($FD, $EC, $E6);
  FVideoAttri.Style := [fsBold];

  FLinkAttri.Foreground := MakeEpubColor($00, $50, $B0);
  FLinkAttri.Background := MakeEpubColor($E8, $F0, $FF);
  FLinkAttri.Style := [fsBold, fsUnderline];

  FUnknownAttri.Foreground := MakeEpubColor($60, $60, $60);
  FUnknownAttri.Background := MakeEpubColor($FF, $F2, $D0);
  FUnknownAttri.Style := [fsItalic];
end;

class function TSynEpubPlaceholderSyn.PlaceholderKindOf(
  const AText: string): TEpubPlaceholderKind;
var
  S, Prefix: string;
  C: Integer;
begin
  S := Trim(AText);
  if (Length(S) >= 4) and (Copy(S, 1, 2) = '{{') and
     (Copy(S, Length(S) - 1, 2) = '}}') then
    S := Trim(Copy(S, 3, Length(S) - 4));
  C := Pos(':', S);
  if C > 0 then
    Prefix := LowerCase(Trim(Copy(S, 1, C - 1)))
  else
    Prefix := LowerCase(Trim(S));

  if Prefix = 'image' then Result := pkImage
  else if Prefix = 'audio' then Result := pkAudio
  else if Prefix = 'video' then Result := pkVideo
  else if Prefix = 'link' then Result := pkLink
  else Result := pkUnknown;
end;

function TSynEpubPlaceholderSyn.AttributeFor(
  AKind: TEpubPlaceholderKind): TSynHighlighterAttributes;
begin
  case AKind of
    pkImage: Result := FImageAttri;
    pkAudio: Result := FAudioAttri;
    pkVideo: Result := FVideoAttri;
    pkLink: Result := FLinkAttri;
  else
    Result := FUnknownAttri;
  end;
end;

procedure TSynEpubPlaceholderSyn.ScanPlaceholders(const ALine: UnicodeString);
var
  P, Q, SearchFrom, N: Integer;
  Whole: string;
begin
  SetLength(FPlaceholders, 0);
  N := 0;
  SearchFrom := 1;
  while True do
  begin
    P := PosEx('{{', ALine, SearchFrom);
    if P = 0 then Break;
    Q := PosEx('}}', ALine, P + 2);
    if Q = 0 then
    begin
      { 未闭合的占位符不着色，继续向后寻找 }
      SearchFrom := P + 2;
      Continue;
    end;
    Whole := string(Copy(ALine, P, Q - P + 2));
    SetLength(FPlaceholders, N + 1);
    FPlaceholders[N].StartPos := P - 1;      { 1-based P -> 0-based }
    FPlaceholders[N].EndPos := Q + 1;        { 结束花括号之后（0-based 开区间） }
    FPlaceholders[N].Kind := PlaceholderKindOf(Whole);
    Inc(N);
    SearchFrom := Q + 2;
  end;
end;

procedure TSynEpubPlaceholderSyn.SetLine(const Value: UnicodeString;
  LineNumber: Integer);
begin
  { 必须先扫描占位符，再让父类 DoSetLine + Next 准备首个 token；
    Next 中占位符分支依赖已扫描好的 FPlaceholders }
  ScanPlaceholders(Value);
  FPhIdx := 0;
  FCurAttri := nil;
  FCurKind := 0;
  inherited SetLine(Value, LineNumber);
end;

procedure TSynEpubPlaceholderSyn.SetLineExpandedAtWideGlyphs(const Line,
  ExpandedLine: UnicodeString; LineNumber: Integer);
begin
  { 关键：必须保留父类传入的 ExpandedLine 与宽字符展开表。SynEdit 绘制使用
    GetExpandedToken/GetExpandedTokenPos，中文等宽字符的行若丢失展开表，
    token 位置会按原始字符数计算，导致文字重叠、串色。占位符按原始 Line
    扫描，位置索引与 FLine 一致，父类 Next 会自动同步展开游标。 }
  ScanPlaceholders(Line);
  FPhIdx := 0;
  FCurAttri := nil;
  FCurKind := 0;
  inherited SetLineExpandedAtWideGlyphs(Line, ExpandedLine, LineNumber);
end;

{ 把展开游标从 AFromExpRun 起，按「原始字符数」ACharDelta 推进。逻辑与
  父类 TSynCustomHighlighter.Next 完全一致：每前进一个原始字符，先跳过
  展开串中的 FillerChar，再跨过该字符本身。注意 ACharDelta 必须是原始
  坐标差（Run - FTokenPos），绝不能把展开坐标当作原始坐标传入，否则
  含中文的行会推进过头，令 GetExpandedToken 错位、尾部 token 丢失。 }
procedure TSynEpubPlaceholderSyn.AdvanceExpanded(AFromExpRun, ACharDelta: Integer);
var
  I: Integer;
begin
  if FExpandedLine = nil then Exit;
  if ACharDelta <= 0 then Exit;
  FExpandedRun := AFromExpRun;
  for I := 1 to ACharDelta do
  begin
    while FExpandedLine[FExpandedRun] = FillerChar do
      Inc(FExpandedRun);
    Inc(FExpandedRun);
  end;
end;

procedure TSynEpubPlaceholderSyn.Next;
var
  StartRun, StartExpRun, NextPhStart: Integer;
begin
  { 记录本次 token 的原始起点与对应的展开游标。父类 Next 结束后，
    FOldRun/FExpandedRun 表示「下一个 token 起点」，因此任何手动截断
    都必须把二者重新对齐到截断后的 Run，否则下一次 Next 的 Delta 会
    用错误的基准，产生串色与位置错位。 }
  StartRun := Run;
  StartExpRun := FExpandedRun;

  { 1) 当前 Run 正好落在某占位符起点：整个占位符作为一个 token }
  if (FPhIdx <= High(FPlaceholders)) and
     (StartRun = FPlaceholders[FPhIdx].StartPos) then
  begin
    FTokenPos := StartRun;
    Run := FPlaceholders[FPhIdx].EndPos;
    FCurAttri := AttributeFor(FPlaceholders[FPhIdx].Kind);
    FCurKind := SYN_EPUB_KIND_BASE + Ord(FPlaceholders[FPhIdx].Kind);
    Inc(FPhIdx);
    { 显式同步展开游标：本分支绕过了父类 Next，必须自行按原始字符数推进。
      StartRun 与 Run 均为原始坐标，差值即占位符的原始字符数。 }
    FExpandedTokenPos := StartExpRun;
    AdvanceExpanded(StartExpRun, Run - StartRun);
    FOldRun := Run;
    Exit;
  end;

  { 2) 交回父类 HTML 词法分析器产出普通 token。父类 Next 末尾的
    TSynCustomHighlighter.Next 会按 FOldRun -> Run 推进 FExpandedRun，
    并把 FOldRun / FExpandedTokenPos 对齐到本次 token 终点。 }
  inherited Next;
  FCurAttri := inherited GetTokenAttribute;
  FCurKind := inherited GetTokenKind;

  { 父类可能把「文本 + 占位符 + 后续文本」合并成一个长 token；
    截断到占位符起点，并把全部游标回退对齐，使下一次 Next 能整体接管 }
  if FPhIdx <= High(FPlaceholders) then
  begin
    NextPhStart := FPlaceholders[FPhIdx].StartPos;
    if (FTokenPos < NextPhStart) and (Run > NextPhStart) then
    begin
      Run := NextPhStart;
      FExpandedTokenPos := StartExpRun;
      FExpandedRun := StartExpRun;
      AdvanceExpanded(StartExpRun, Run - StartRun);
      FOldRun := Run;
    end
    else if FTokenPos >= NextPhStart then
      Inc(FPhIdx);               { 容错：父类已越过该占位符 }
  end;
end;

function TSynEpubPlaceholderSyn.GetEol: Boolean;
begin
  { 与父类 TSynHTMLSyn 一致：NullProc 会把 Run 推进到 FLineLen + 1 }
  Result := Run >= FLineLen + 1;
end;

function TSynEpubPlaceholderSyn.GetTokenAttribute: TSynHighlighterAttributes;
begin
  Result := FCurAttri;
  if Result = nil then
    Result := inherited GetTokenAttribute;
end;

function TSynEpubPlaceholderSyn.GetTokenKind: Integer;
begin
  Result := FCurKind;
end;

procedure TSynEpubPlaceholderSyn.ApplyIniToAttribute(AIni: TIniFile;
  AAttri: TSynHighlighterAttributes);
var
  Section: string;
begin
  Section := 'Placeholder.' + AAttri.Name;
  AAttri.Foreground := TColor(AIni.ReadInteger(Section, 'Foreground',
    Integer(AAttri.Foreground)));
  AAttri.Background := TColor(AIni.ReadInteger(Section, 'Background',
    Integer(AAttri.Background)));
  AAttri.IntegerStyle := AIni.ReadInteger(Section, 'Style', AAttri.IntegerStyle);
end;

procedure TSynEpubPlaceholderSyn.WriteAttributeToIni(AIni: TIniFile;
  AAttri: TSynHighlighterAttributes);
var
  Section: string;
begin
  Section := 'Placeholder.' + AAttri.Name;
  AIni.WriteInteger(Section, 'Foreground', Integer(AAttri.Foreground));
  AIni.WriteInteger(Section, 'Background', Integer(AAttri.Background));
  AIni.WriteInteger(Section, 'Style', AAttri.IntegerStyle);
end;

procedure TSynEpubPlaceholderSyn.LoadStyleSettings(const AIniFile: string);
var
  Ini: TIniFile;
begin
  if (AIniFile = '') or (not FileExists(AIniFile)) then Exit;
  Ini := TIniFile.Create(AIniFile);
  try
    try
      ApplyIniToAttribute(Ini, FImageAttri);
      ApplyIniToAttribute(Ini, FAudioAttri);
      ApplyIniToAttribute(Ini, FVideoAttri);
      ApplyIniToAttribute(Ini, FLinkAttri);
      ApplyIniToAttribute(Ini, FUnknownAttri);
    except
      on E: Exception do ;   { 配置损坏时静默沿用默认样式 }
    end;
  finally
    Ini.Free;
  end;
end;

procedure TSynEpubPlaceholderSyn.SaveStyleSettings(const AIniFile: string);
var
  Ini: TIniFile;
begin
  if AIniFile = '' then Exit;
  Ini := TIniFile.Create(AIniFile);
  try
    try
      WriteAttributeToIni(Ini, FImageAttri);
      WriteAttributeToIni(Ini, FAudioAttri);
      WriteAttributeToIni(Ini, FVideoAttri);
      WriteAttributeToIni(Ini, FLinkAttri);
      WriteAttributeToIni(Ini, FUnknownAttri);
      Ini.UpdateFile;
    except
      on E: Exception do ;   { 目录不可写时忽略，不影响编辑 }
    end;
  finally
    Ini.Free;
  end;
end;

end.
