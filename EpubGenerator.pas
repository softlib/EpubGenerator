unit EpubGenerator;

{==============================================================================
  EpubGenerator.pas  ——  基于 Delphi 12.2 System.Zip 的通用 EPUB 3.0 生成器

  设计目标
  ---------------------------------------------------------------------------
  1. 不依赖任何第三方库，仅使用 RTL（System.Zip / System.Classes / Generics）。
  2. 生成器与内容解耦：先声明元数据、章节、图片、音频、视频、样式等资源，
     最后一次性打包成符合 EPUB 3.0 规范的 .epub 文件。
  3. 自动生成 mimetype / container.xml / content.opf / nav.xhtml / toc.ncx，
     并处理封面、目录层级、媒体类型、XML 转义等细节。
  4. 音视频通过形如【audio:id】的占位符或 AudioTag/VideoTag
     辅助函数插入正文，生成器负责换算包内相对路径。

  典型用法
  ---------------------------------------------------------------------------
    var G: TEpubGenerator;
    begin
      G := TEpubGenerator.Create;
      try
        G.Metadata.Title  := '我的电子书';
        G.Metadata.Author := '作者';
        G.AddPlainTextChapter('第一章', '正文内容...');
        G.AddAudio('C:\media\a.mp3');
        G.SaveToFile('C:\out\book.epub');
      finally
        G.Free;
      end;
    end;

  包内目录约定
  ---------------------------------------------------------------------------
    mimetype                       (必须第一个、不压缩)
    META-INF/container.xml
    OEBPS/content.opf
    OEBPS/nav.xhtml
    OEBPS/toc.ncx                  (可选，兼容 EPUB 2 阅读器)
    OEBPS/Styles/*.css
    OEBPS/Text/*.xhtml
    OEBPS/Images/*
    OEBPS/Media/*                  (音频、视频)
    OEBPS/Fonts/*
    OEBPS/Misc/*
==============================================================================}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.Zip,
  System.IOUtils,
  System.DateUtils;

type
  EEpubError = class(Exception);

  TEpubAssetKind = (akImage, akAudio, akVideo, akStyle, akFont, akSmil, akOther);

  { 一个包内资源（图片 / 音频 / 视频 / 样式 / 字体 / SMIL / 其他） }
  TEpubAsset = class
  private
    FId: string;
    FHref: string;          // 相对 OEBPS，例如 Media/track01.mp3
    FSourceFile: string;    // 磁盘源文件；为空时使用内存数据
    FMimeType: string;
    FKind: TEpubAssetKind;
    FProperties: string;    // OPF properties，例如 cover-image
    FData: TBytes;          // 内存数据
    FAlt: string;
  public
    constructor Create(const AId, AHref: string; AKind: TEpubAssetKind);
    property Id: string read FId write FId;
    property Href: string read FHref write FHref;
    property SourceFile: string read FSourceFile write FSourceFile;
    property MimeType: string read FMimeType write FMimeType;
    property Kind: TEpubAssetKind read FKind write FKind;
    property Properties: string read FProperties write FProperties;
    property Data: TBytes read FData write FData;
    property Alt: string read FAlt write FAlt;
  end;

  { 一个章节（同时是 spine 条目和目录条目） }
  TEpubChapter = class
  private
    FId: string;
    FTitle: string;
    FHref: string;          // 相对 OEBPS，例如 Text/chapter001.xhtml
    FBody: string;          // XHTML body 内部片段，或完整 XHTML 文档
    FFullDocument: Boolean; // True 表示 FBody 已是完整 XHTML 文档
    FLevel: Integer;        // 目录层级，1 为顶层
    FParentId: string;      // 父章节 Id，空表示顶层
    FInToc: Boolean;
    FMediaOverlayId: string;
  public
    constructor Create(const AId, ATitle, AHref: string);
    property Id: string read FId write FId;
    property Title: string read FTitle write FTitle;
    property Href: string read FHref write FHref;
    property Body: string read FBody write FBody;
    property FullDocument: Boolean read FFullDocument write FFullDocument;
    property Level: Integer read FLevel write FLevel;
    property ParentId: string read FParentId write FParentId;
    property InToc: Boolean read FInToc write FInToc;
    property MediaOverlayId: string read FMediaOverlayId write FMediaOverlayId;
  end;

  {  Dublin Core 元数据  }
  TEpubMetadata = class
  private
    FTitle: string;
    FLanguage: string;
    FIdentifier: string;
    FPublisher: string;
    FDescription: string;
    FSubject: string;
    FDate: string;
    FRights: string;
    FContributor: string;
    FAuthors: TStringList;
    FModifiedUTC: TDateTime;
    function GetAuthor: string;
    procedure SetAuthor(const AValue: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddAuthor(const AName: string);
    procedure ClearAuthors;
    property Title: string read FTitle write FTitle;
    property Author: string read GetAuthor write SetAuthor;
    property Authors: TStringList read FAuthors;
    property Language: string read FLanguage write FLanguage;
    property Identifier: string read FIdentifier write FIdentifier;
    property Publisher: string read FPublisher write FPublisher;
    property Description: string read FDescription write FDescription;
    property Subject: string read FSubject write FSubject;
    property Date: string read FDate write FDate;
    property Rights: string read FRights write FRights;
    property Contributor: string read FContributor write FContributor;
    property ModifiedUTC: TDateTime read FModifiedUTC write FModifiedUTC;
  end;

  { EPUB 生成器主类 }
  TEpubGenerator = class
  private
    FMetadata: TEpubMetadata;
    FChapters: TObjectList<TEpubChapter>;
    FAssets: TObjectList<TEpubAsset>;
    FGenerateNCX: Boolean;
    FAutoLinkStyles: Boolean;
    FCoverAssetId: string;
    FCoverChapterId: string;
    FNavTitle: string;
    FIdCounter: Integer;

    function NewId(const APrefix: string): string;
    function FindAsset(const AId: string): TEpubAsset;
    function FindChapter(const AId: string): TEpubChapter;
    function FromTextDir(const AHref: string): string;
    class function StripOebps(const AHref: string): string; static;
    class function FileNameOf(const AHref: string): string; static;
    function ExpandTokens(const AText: string): string;
    function BuildChapterDocument(AChapter: TEpubChapter): string;
    function BuildContainerXml: string;
    function BuildOpf: string;
    function BuildNavXhtml: string;
    function BuildNcx: string;
    function BuildNavList(AParentId: string; ALevel: Integer): string;
    function BuildNcxPoints(AParentId: string; ALevel: Integer; var APlayOrder: Integer): string;
    procedure AddTextEntry(AZip: TZipFile; const AArchiveName, AText: string;
      ACompression: TZipCompression = zcDeflate);
    procedure AddAssetEntry(AZip: TZipFile; AAsset: TEpubAsset);
    procedure BuildPackage(AZip: TZipFile);
  public
    constructor Create;
    destructor Destroy; override;

    property Metadata: TEpubMetadata read FMetadata;
    property GenerateNCX: Boolean read FGenerateNCX write FGenerateNCX;
    property AutoLinkStyles: Boolean read FAutoLinkStyles write FAutoLinkStyles;
    property NavTitle: string read FNavTitle write FNavTitle;

    { 章节 }
    function AddChapter(const ATitle, AXhtmlBody: string;
      const AFileName: string = ''): TEpubChapter; overload;
    function AddChapter(const ATitle, AXhtmlBody: string; ALevel: Integer;
      const AParentId: string; const AFileName: string = ''): TEpubChapter; overload;
    function AddPlainTextChapter(const ATitle, APlainText: string;
      const AFileName: string = ''): TEpubChapter;
    function AddChapterFromFile(const ATitle, AXhtmlFile: string;
      const AFileName: string = ''): TEpubChapter;

    { 资源 }
    function AddImage(const ASourceFile: string; const AArchiveName: string = '';
      const AMimeType: string = ''): TEpubAsset;
    function AddAudio(const ASourceFile: string; const AArchiveName: string = '';
      const AMimeType: string = ''): TEpubAsset;
    function AddVideo(const ASourceFile: string; const AArchiveName: string = '';
      const AMimeType: string = ''): TEpubAsset;
    function AddStyle(const ASourceFile: string; const AArchiveName: string = ''): TEpubAsset;
    function AddStyleText(const AName, ACssText: string): TEpubAsset;
    function AddFont(const ASourceFile: string; const AArchiveName: string = ''): TEpubAsset;
    function AddAsset(const ASourceFile, AArchiveName, AMimeType: string;
      AKind: TEpubAssetKind): TEpubAsset;
    function AddBytesAsset(const AArchiveName, AMimeType: string; const AData: TBytes;
      AKind: TEpubAssetKind): TEpubAsset;
    function AddCoverImage(const ASourceFile: string;
      const AArchiveName: string = ''): TEpubAsset;
    procedure SetCoverChapter(AChapter: TEpubChapter);
    function AddMediaOverlay(AChapter: TEpubChapter; const ASmilFile: string;
      const AArchiveName: string = ''): TEpubAsset;

    { 输出 }
    procedure SaveToFile(const AFileName: string);
    procedure SaveToStream(AStream: TStream);
    procedure Clear;

    { 工具 }
    class function GuessMimeType(const AFileName: string): string; static;
    class function XmlEncode(const S: string; AAttribute: Boolean = False): string; static;
    class function NormalizePath(const APath: string): string; static;
    class function AudioTag(const AHref, AFallback: string): string; static;
    class function VideoTag(const AHref, APosterHref, AFallback: string): string; static;
    class function ImageTag(const AHref, AAlt: string): string; static;
  end;

implementation

uses
  System.Math, System.StrUtils;

const
  EPUB_NS      = 'http://www.idpf.org/2007/opf';
  DC_NS        = 'http://purl.org/dc/elements/1.1/';
  XHTML_NS     = 'http://www.w3.org/1999/xhtml';
  EPUB_OPS_NS  = 'http://www.idpf.org/2007/ops';
  NCX_NS       = 'http://www.daisy.org/z3986/2005/ncx/';
  SMIL_NS      = 'http://www.w3.org/ns/SMIL';
  CONTAINER_NS = 'urn:oasis:names:tc:opendocument:xmlns:container';

  DIR_BY_KIND: array[TEpubAssetKind] of string =
    ('Images', 'Media', 'Media', 'Styles', 'Fonts', 'Misc', 'Misc');

{------------------------------------------------------------------------------
  TEpubAsset
------------------------------------------------------------------------------}

constructor TEpubAsset.Create(const AId, AHref: string; AKind: TEpubAssetKind);
begin
  inherited Create;
  FId := AId;
  FHref := AHref;
  FKind := AKind;
end;

{------------------------------------------------------------------------------
  TEpubChapter
------------------------------------------------------------------------------}

constructor TEpubChapter.Create(const AId, ATitle, AHref: string);
begin
  inherited Create;
  FId := AId;
  FTitle := ATitle;
  FHref := AHref;
  FLevel := 1;
  FInToc := True;
end;

{------------------------------------------------------------------------------
  TEpubMetadata
------------------------------------------------------------------------------}

constructor TEpubMetadata.Create;
var
  G: TGUID;
begin
  inherited Create;
  FAuthors := TStringList.Create;
  FLanguage := 'zh-CN';
  FDate := FormatDateTime('yyyy-mm-dd', Now);
  FModifiedUTC := TTimeZone.Local.ToUniversalTime(Now);
  CreateGUID(G);
  FIdentifier := 'urn:uuid:' + Copy(GUIDToString(G), 2, 36);
end;

destructor TEpubMetadata.Destroy;
begin
  FAuthors.Free;
  inherited Destroy;
end;

function TEpubMetadata.GetAuthor: string;
begin
  if FAuthors.Count > 0 then
    Result := FAuthors[0]
  else
    Result := '';
end;

procedure TEpubMetadata.SetAuthor(const AValue: string);
begin
  ClearAuthors;
  if AValue <> '' then
    FAuthors.Add(AValue);
end;

procedure TEpubMetadata.AddAuthor(const AName: string);
begin
  if AName <> '' then
    FAuthors.Add(AName);
end;

procedure TEpubMetadata.ClearAuthors;
begin
  FAuthors.Clear;
end;

{------------------------------------------------------------------------------
  TEpubGenerator - 创建 / 销毁
------------------------------------------------------------------------------}

constructor TEpubGenerator.Create;
begin
  inherited Create;
  FMetadata := TEpubMetadata.Create;
  FChapters := TObjectList<TEpubChapter>.Create(True);
  FAssets := TObjectList<TEpubAsset>.Create(True);
  FGenerateNCX := True;
  FAutoLinkStyles := True;
  FNavTitle := '目录';
end;

destructor TEpubGenerator.Destroy;
begin
  FAssets.Free;
  FChapters.Free;
  FMetadata.Free;
  inherited Destroy;
end;

procedure TEpubGenerator.Clear;
begin
  FChapters.Clear;
  FAssets.Clear;
  FCoverAssetId := '';
  FCoverChapterId := '';
  FIdCounter := 0;
end;

function TEpubGenerator.NewId(const APrefix: string): string;
begin
  Inc(FIdCounter);
  Result := APrefix + Format('%.3d', [FIdCounter]);
end;

function TEpubGenerator.FindAsset(const AId: string): TEpubAsset;
var
  I: Integer;
begin
  for I := 0 to FAssets.Count - 1 do
    if SameText(FAssets[I].Id, AId) then
      Exit(FAssets[I]);
  Result := nil;
end;

function TEpubGenerator.FindChapter(const AId: string): TEpubChapter;
var
  I: Integer;
begin
  for I := 0 to FChapters.Count - 1 do
    if SameText(FChapters[I].Id, AId) then
      Exit(FChapters[I]);
  Result := nil;
end;

{------------------------------------------------------------------------------
  工具函数
------------------------------------------------------------------------------}

class function TEpubGenerator.XmlEncode(const S: string; AAttribute: Boolean): string;
var
  I: Integer;
  C: Char;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 1 to Length(S) do
    begin
      C := S[I];
      case C of
        '&':  SB.Append('&amp;');
        '<':  SB.Append('&lt;');
        '>':  SB.Append('&gt;');
        '"':  if AAttribute then SB.Append('&quot;') else SB.Append('"');
        '''': SB.Append('&apos;');
        #0..#8, #11, #12, #14..#31: ; // XML 1.0 非法控制字符，直接丢弃
      else
        SB.Append(C);
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

class function TEpubGenerator.NormalizePath(const APath: string): string;
var
  Segs, Parts: TArray<string>;
  Seg: string;
  Stack: TStringList;
  I: Integer;
begin
  Segs := APath.Replace('\', '/', [rfReplaceAll]).Split(['/']);
  Stack := TStringList.Create;
  try
    for Seg in Segs do
    begin
      if (Seg = '') or (Seg = '.') then
        Continue;
      if Seg = '..' then
      begin
        if Stack.Count > 0 then
          Stack.Delete(Stack.Count - 1);
      end
      else
        Stack.Add(Seg);
    end;
    SetLength(Parts, Stack.Count);
    for I := 0 to Stack.Count - 1 do
      Parts[I] := Stack[I];
    Result := string.Join('/', Parts);
  finally
    Stack.Free;
  end;
end;

class function TEpubGenerator.GuessMimeType(const AFileName: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  if Ext = '' then
    Exit('application/octet-stream');
  Delete(Ext, 1, 1); // 去掉点

  if Ext = 'jpg'  then Exit('image/jpeg');
  if Ext = 'jpeg' then Exit('image/jpeg');
  if Ext = 'png'  then Exit('image/png');
  if Ext = 'gif'  then Exit('image/gif');
  if Ext = 'svg'  then Exit('image/svg+xml');
  if Ext = 'webp' then Exit('image/webp');
  if Ext = 'bmp'  then Exit('image/bmp');
  if Ext = 'avif' then Exit('image/avif');
  if Ext = 'tif'  then Exit('image/tiff');
  if Ext = 'tiff' then Exit('image/tiff');

  if Ext = 'mp3'  then Exit('audio/mpeg');
  if Ext = 'm4a'  then Exit('audio/mp4');
  if Ext = 'aac'  then Exit('audio/aac');
  if Ext = 'ogg'  then Exit('audio/ogg');
  if Ext = 'oga'  then Exit('audio/ogg');
  if Ext = 'opus' then Exit('audio/ogg');
  if Ext = 'wav'  then Exit('audio/wav');
  if Ext = 'flac' then Exit('audio/flac');
  if Ext = 'mid'  then Exit('audio/midi');
  if Ext = 'midi' then Exit('audio/midi');

  if Ext = 'mp4'  then Exit('video/mp4');
  if Ext = 'm4v'  then Exit('video/mp4');
  if Ext = 'webm' then Exit('video/webm');
  if Ext = 'ogv'  then Exit('video/ogg');
  if Ext = 'mkv'  then Exit('video/x-matroska');
  if Ext = 'avi'  then Exit('video/x-msvideo');

  if Ext = 'css'  then Exit('text/css');
  if Ext = 'js'   then Exit('application/javascript');
  if Ext = 'xhtml' then Exit('application/xhtml+xml');
  if Ext = 'html' then Exit('application/xhtml+xml');
  if Ext = 'htm'  then Exit('application/xhtml+xml');
  if Ext = 'xml'  then Exit('application/xml');
  if Ext = 'smil' then Exit('application/smil+xml');
  if Ext = 'ncx'  then Exit('application/x-dtbncx+xml');
  if Ext = 'txt'  then Exit('text/plain');
  if Ext = 'json' then Exit('application/json');
  if Ext = 'pdf'  then Exit('application/pdf');

  if Ext = 'woff'  then Exit('font/woff');
  if Ext = 'woff2' then Exit('font/woff2');
  if Ext = 'ttf'   then Exit('font/ttf');
  if Ext = 'otf'   then Exit('font/otf');
  if Ext = 'eot'   then Exit('application/vnd.ms-fontobject');

  Result := 'application/octet-stream';
end;

class function TEpubGenerator.AudioTag(const AHref, AFallback: string): string;
begin
  Result := '<audio src="' + XmlEncode(AHref, True) + '" controls="controls">' +
            XmlEncode(AFallback) + '</audio>';
end;

class function TEpubGenerator.VideoTag(const AHref, APosterHref, AFallback: string): string;
begin
  Result := '<video src="' + XmlEncode(AHref, True) + '" controls="controls"';
  if APosterHref <> '' then
    Result := Result + ' poster="' + XmlEncode(APosterHref, True) + '"';
  Result := Result + '>' + XmlEncode(AFallback) + '</video>';
end;

class function TEpubGenerator.ImageTag(const AHref, AAlt: string): string;
begin
  Result := '<img src="' + XmlEncode(AHref, True) + '" alt="' +
            XmlEncode(AAlt, True) + '"/>';
end;

class function TEpubGenerator.StripOebps(const AHref: string): string;
begin
  if AHref.StartsWith('OEBPS/') then
    Result := Copy(AHref, 7, MaxInt)
  else
    Result := AHref;
end;

class function TEpubGenerator.FileNameOf(const AHref: string): string;
var
  P: Integer;
begin
  P := LastDelimiter('/' + '\', AHref);
  Result := Copy(AHref, P + 1, MaxInt);
end;

function TEpubGenerator.FromTextDir(const AHref: string): string;
begin
  // 章节位于 OEBPS/Text/，从章节看 OEBPS 下其他资源需加 ../
  Result := '../' + StripOebps(NormalizePath(AHref));
end;

{------------------------------------------------------------------------------
  章节
------------------------------------------------------------------------------}

function TEpubGenerator.AddChapter(const ATitle, AXhtmlBody: string;
  const AFileName: string): TEpubChapter;
begin
  Result := AddChapter(ATitle, AXhtmlBody, 1, '', AFileName);
end;

function TEpubGenerator.AddChapter(const ATitle, AXhtmlBody: string;
  ALevel: Integer; const AParentId: string; const AFileName: string): TEpubChapter;
var
  Name: string;
begin
  Name := AFileName;
  if Name = '' then
    Name := 'chapter' + Format('%.3d', [FChapters.Count + 1]) + '.xhtml';
  Name := ExtractFileName(StringReplace(Name, '\', '/', [rfReplaceAll]));
  if ExtractFileExt(Name) = '' then
    Name := Name + '.xhtml';

  Result := TEpubChapter.Create(NewId('chap'), ATitle,
    NormalizePath('OEBPS/Text/' + Name));
  Result.Body := AXhtmlBody;
  Result.Level := Max(1, ALevel);
  Result.ParentId := AParentId;
  FChapters.Add(Result);
end;

function TEpubGenerator.AddPlainTextChapter(const ATitle, APlainText: string;
  const AFileName: string): TEpubChapter;
var
  Lines: TArray<string>;
  Line: string;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('<h1>').Append(XmlEncode(ATitle)).Append('</h1>').Append(sLineBreak);
    Lines := APlainText.Split([#10, #13], TStringSplitOptions.ExcludeEmpty);
    for Line in Lines do
      SB.Append('<p>').Append(XmlEncode(Trim(Line))).Append('</p>').Append(sLineBreak);
    Result := AddChapter(ATitle, SB.ToString, AFileName);
  finally
    SB.Free;
  end;
end;

function TEpubGenerator.AddChapterFromFile(const ATitle, AXhtmlFile: string;
  const AFileName: string): TEpubChapter;
var
  Text, LowerText: string;
  P1, P2: Integer;
  Name: string;
begin
  if not TFile.Exists(AXhtmlFile) then
    raise EEpubError.CreateFmt('找不到章节文件: %s', [AXhtmlFile]);

  Text := TFile.ReadAllText(AXhtmlFile, TEncoding.UTF8);
  LowerText := LowerCase(Text);
  P1 := Pos('<body', LowerText);
  if P1 > 0 then
  begin
    P1 := PosEx('>', Text, P1) + 1;
    P2 := Pos('</body>', LowerText);
    if P2 > P1 then
      Text := Copy(Text, P1, P2 - P1);
  end;

  Name := AFileName;
  if Name = '' then
    Name := ExtractFileName(AXhtmlFile);
  Result := AddChapter(ATitle, Text, Name);
end;

{------------------------------------------------------------------------------
  资源
------------------------------------------------------------------------------}

function TEpubGenerator.AddAsset(const ASourceFile, AArchiveName, AMimeType: string;
  AKind: TEpubAssetKind): TEpubAsset;
var
  Name, Target: string;
begin
  if not TFile.Exists(ASourceFile) then
    raise EEpubError.CreateFmt('找不到资源文件: %s', [ASourceFile]);

  Name := AArchiveName;
  if Name = '' then
    Name := ExtractFileName(ASourceFile);
  Name := ExtractFileName(StringReplace(Name, '\', '/', [rfReplaceAll]));
  Target := NormalizePath('OEBPS/' + DIR_BY_KIND[AKind] + '/' + Name);

  Result := TEpubAsset.Create(NewId('res'), Target, AKind);
  Result.SourceFile := ASourceFile;
  Result.MimeType := AMimeType;
  if Result.MimeType = '' then
    Result.MimeType := GuessMimeType(ASourceFile);
  Result.Alt := ChangeFileExt(ExtractFileName(ASourceFile), '');
  FAssets.Add(Result);
end;

function TEpubGenerator.AddBytesAsset(const AArchiveName, AMimeType: string;
  const AData: TBytes; AKind: TEpubAssetKind): TEpubAsset;
var
  Name, Target: string;
begin
  Name := ExtractFileName(StringReplace(AArchiveName, '\', '/', [rfReplaceAll]));
  Target := NormalizePath('OEBPS/' + DIR_BY_KIND[AKind] + '/' + Name);
  Result := TEpubAsset.Create(NewId('res'), Target, AKind);
  Result.MimeType := AMimeType;
  if Result.MimeType = '' then
    Result.MimeType := GuessMimeType(Name);
  Result.Data := Copy(AData);
  FAssets.Add(Result);
end;

function TEpubGenerator.AddImage(const ASourceFile, AArchiveName, AMimeType: string): TEpubAsset;
begin
  Result := AddAsset(ASourceFile, AArchiveName, AMimeType, akImage);
end;

function TEpubGenerator.AddAudio(const ASourceFile, AArchiveName, AMimeType: string): TEpubAsset;
begin
  Result := AddAsset(ASourceFile, AArchiveName, AMimeType, akAudio);
end;

function TEpubGenerator.AddVideo(const ASourceFile, AArchiveName, AMimeType: string): TEpubAsset;
begin
  Result := AddAsset(ASourceFile, AArchiveName, AMimeType, akVideo);
end;

function TEpubGenerator.AddFont(const ASourceFile, AArchiveName: string): TEpubAsset;
begin
  Result := AddAsset(ASourceFile, AArchiveName, '', akFont);
end;

function TEpubGenerator.AddStyle(const ASourceFile, AArchiveName: string): TEpubAsset;
begin
  Result := AddAsset(ASourceFile, AArchiveName, 'text/css', akStyle);
end;

function TEpubGenerator.AddStyleText(const AName, ACssText: string): TEpubAsset;
begin
  Result := AddBytesAsset(AName, 'text/css', TEncoding.UTF8.GetBytes(ACssText), akStyle);
end;

function TEpubGenerator.AddCoverImage(const ASourceFile, AArchiveName: string): TEpubAsset;
begin
  Result := AddImage(ASourceFile, AArchiveName, '');
  Result.Properties := 'cover-image';
  FCoverAssetId := Result.Id;
end;

procedure TEpubGenerator.SetCoverChapter(AChapter: TEpubChapter);
begin
  if AChapter = nil then
    FCoverChapterId := ''
  else
    FCoverChapterId := AChapter.Id;
end;

function TEpubGenerator.AddMediaOverlay(AChapter: TEpubChapter;
  const ASmilFile, AArchiveName: string): TEpubAsset;
var
  Name: string;
begin
  if AChapter = nil then
    raise EEpubError.Create('AddMediaOverlay: AChapter 不能为空');
    Name := AArchiveName;
    if Name = '' then
      Name := AChapter.Id + '.smil';
  Result := AddAsset(ASmilFile, Name, 'application/smil+xml', akSmil);
  AChapter.MediaOverlayId := Result.Id;
end;

{------------------------------------------------------------------------------
  正文占位符展开
------------------------------------------------------------------------------}

function TEpubGenerator.ExpandTokens(const AText: string): string;
var
  P, Q, ClosePos: Integer;
  Token, Key, Id: string;
  A: TEpubAsset;
  C: TEpubChapter;
  Replacement: string;
begin
  Result := AText;
  P := Pos('{{', Result);
  while P > 0 do
  begin
    ClosePos := PosEx('}}', Result, P + 2);
    if ClosePos = 0 then
      Break;
    Token := Copy(Result, P + 2, ClosePos - P - 2);
    Q := Pos(':', Token);
    Replacement := '';
    if Q > 0 then
    begin
      Key := LowerCase(Trim(Copy(Token, 1, Q - 1)));
      Id := Trim(Copy(Token, Q + 1, MaxInt));
      if Key = 'audio' then
      begin
        A := FindAsset(Id);
        if A <> nil then
          Replacement := AudioTag(FromTextDir(A.Href), '您的浏览器不支持音频播放')
        else
          raise EEpubError.CreateFmt('未知的音频占位符: {{%s}}', [Token]);
      end
      else if Key = 'video' then
      begin
        A := FindAsset(Id);
        if A <> nil then
          Replacement := VideoTag(FromTextDir(A.Href), '', '您的浏览器不支持视频播放')
        else
          raise EEpubError.CreateFmt('未知的视频占位符: {{%s}}', [Token]);
      end
      else if Key = 'image' then
      begin
        A := FindAsset(Id);
        if A <> nil then
          Replacement := ImageTag(FromTextDir(A.Href), A.Alt)
        else
          raise EEpubError.CreateFmt('未知的图片占位符: {{%s}}', [Token]);
      end
      else if Key = 'link' then
      begin
        C := FindChapter(Id);
        if C <> nil then
          Replacement := '<a href="' + XmlEncode(FileNameOf(C.Href), True) +
                         '">' + XmlEncode(C.Title) + '</a>'
        else
          raise EEpubError.CreateFmt('未知的章节占位符: {{%s}}', [Token]);
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
end;

function TEpubGenerator.BuildChapterDocument(AChapter: TEpubChapter): string;
var
  SB: TStringBuilder;
  I: Integer;
  A: TEpubAsset;
  MO: TEpubAsset;
  Body: string;
begin
  Body := ExpandTokens(AChapter.Body);

  SB := TStringBuilder.Create;
  try
    if AChapter.FullDocument then
      Exit(Body);

    SB.Append('<?xml version="1.0" encoding="UTF-8"?>').Append(sLineBreak);
    SB.Append('<!DOCTYPE html>').Append(sLineBreak);
    SB.Append('<html xmlns="').Append(XHTML_NS).Append('" xmlns:epub="')
      .Append(EPUB_OPS_NS).Append('" xml:lang="')
      .Append(XmlEncode(FMetadata.Language, True)).Append('">').Append(sLineBreak);
    SB.Append('<head>').Append(sLineBreak);
    SB.Append('  <title>').Append(XmlEncode(AChapter.Title)).Append('</title>').Append(sLineBreak);
    SB.Append('  <meta charset="utf-8"/>').Append(sLineBreak);

    if FAutoLinkStyles then
      for I := 0 to FAssets.Count - 1 do
      begin
        A := FAssets[I];
        if A.Kind = akStyle then
          SB.Append('  <link rel="stylesheet" type="text/css" href="')
            .Append(XmlEncode(FromTextDir(A.Href), True)).Append('"/>').Append(sLineBreak);
      end;

    SB.Append('</head>').Append(sLineBreak);

    SB.Append('<body');
    if AChapter.MediaOverlayId <> '' then
    begin
      MO := FindAsset(AChapter.MediaOverlayId);
      if MO <> nil then
        SB.Append(' media-overlay="').Append(XmlEncode(FromTextDir(MO.Href), True)).Append('"');
    end;
    SB.Append('>').Append(sLineBreak);
    SB.Append(Body).Append(sLineBreak);
    SB.Append('</body>').Append(sLineBreak);
    SB.Append('</html>').Append(sLineBreak);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{------------------------------------------------------------------------------
  container.xml / OPF
------------------------------------------------------------------------------}

function TEpubGenerator.BuildContainerXml: string;
begin
  Result := '<?xml version="1.0" encoding="UTF-8"?>' + sLineBreak +
    '<container version="1.0" xmlns="' + CONTAINER_NS + '">' + sLineBreak +
    '  <rootfiles>' + sLineBreak +
    '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>' + sLineBreak +
    '  </rootfiles>' + sLineBreak +
    '</container>' + sLineBreak;
end;

function TEpubGenerator.BuildOpf: string;
var
  SB: TStringBuilder;
  I: Integer;
  A: TEpubAsset;
  C: TEpubChapter;

  procedure AddItem(const AId, AHref, AMime, AProps: string);
  begin
    SB.Append('    <item id="').Append(XmlEncode(AId, True)).Append('"');
    SB.Append(' href="').Append(XmlEncode(AHref, True)).Append('"');
    SB.Append(' media-type="').Append(XmlEncode(AMime, True)).Append('"');
    if AProps <> '' then
      SB.Append(' properties="').Append(XmlEncode(AProps, True)).Append('"');
    SB.Append('/>').Append(sLineBreak);
  end;

begin
  SB := TStringBuilder.Create;
  try
    SB.Append('<?xml version="1.0" encoding="UTF-8"?>').Append(sLineBreak);
    SB.Append('<package xmlns="').Append(EPUB_NS).Append('" version="3.0"')
      .Append(' unique-identifier="pub-id" xml:lang="')
      .Append(XmlEncode(FMetadata.Language, True)).Append('">').Append(sLineBreak);

    SB.Append('  <metadata xmlns:dc="').Append(DC_NS).Append('">').Append(sLineBreak);
    if FMetadata.Title = '' then
      SB.Append('    <dc:title>Untitled</dc:title>').Append(sLineBreak)
    else
      SB.Append('    <dc:title>').Append(XmlEncode(FMetadata.Title)).Append('</dc:title>').Append(sLineBreak);

    for I := 0 to FMetadata.Authors.Count - 1 do
    begin
      SB.Append('    <dc:creator id="creator').Append(I.ToString).Append('">')
        .Append(XmlEncode(FMetadata.Authors[I])).Append('</dc:creator>').Append(sLineBreak);
      SB.Append('    <meta refines="#creator').Append(I.ToString)
        .Append('" property="role" scheme="marc:relators">aut</meta>').Append(sLineBreak);
    end;

    SB.Append('    <dc:language>').Append(XmlEncode(FMetadata.Language)).Append('</dc:language>').Append(sLineBreak);
    SB.Append('    <dc:identifier id="pub-id">')
      .Append(XmlEncode(FMetadata.Identifier)).Append('</dc:identifier>').Append(sLineBreak);

    if FMetadata.Publisher <> '' then
      SB.Append('    <dc:publisher>').Append(XmlEncode(FMetadata.Publisher)).Append('</dc:publisher>').Append(sLineBreak);
    if FMetadata.Description <> '' then
      SB.Append('    <dc:description>').Append(XmlEncode(FMetadata.Description)).Append('</dc:description>').Append(sLineBreak);
    if FMetadata.Subject <> '' then
      SB.Append('    <dc:subject>').Append(XmlEncode(FMetadata.Subject)).Append('</dc:subject>').Append(sLineBreak);
    if FMetadata.Date <> '' then
      SB.Append('    <dc:date>').Append(XmlEncode(FMetadata.Date)).Append('</dc:date>').Append(sLineBreak);
    if FMetadata.Rights <> '' then
      SB.Append('    <dc:rights>').Append(XmlEncode(FMetadata.Rights)).Append('</dc:rights>').Append(sLineBreak);
    if FMetadata.Contributor <> '' then
      SB.Append('    <dc:contributor>').Append(XmlEncode(FMetadata.Contributor)).Append('</dc:contributor>').Append(sLineBreak);

    SB.Append('    <meta property="dcterms:modified">')
      .Append(FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', FMetadata.ModifiedUTC))
      .Append('</meta>').Append(sLineBreak);
    SB.Append('    <meta property="rendition:layout">reflowable</meta>').Append(sLineBreak);
    SB.Append('    <meta property="rendition:orientation">auto</meta>').Append(sLineBreak);
    SB.Append('    <meta property="rendition:spread">auto</meta>').Append(sLineBreak);
    SB.Append('  </metadata>').Append(sLineBreak);

    SB.Append('  <manifest>').Append(sLineBreak);
    AddItem('nav', 'nav.xhtml', 'application/xhtml+xml', 'nav');
    if FGenerateNCX then
      AddItem('ncx', 'toc.ncx', 'application/x-dtbncx+xml', '');

    for I := 0 to FAssets.Count - 1 do
    begin
      A := FAssets[I];
      AddItem(A.Id, StripOebps(A.Href), A.MimeType, A.Properties);
    end;

    for I := 0 to FChapters.Count - 1 do
    begin
      C := FChapters[I];
      AddItem(C.Id, StripOebps(C.Href), 'application/xhtml+xml', '');
    end;
    SB.Append('  </manifest>').Append(sLineBreak);

    SB.Append('  <spine');
    if FGenerateNCX then
      SB.Append(' toc="ncx"');
    SB.Append('>').Append(sLineBreak);
    for I := 0 to FChapters.Count - 1 do
      SB.Append('    <itemref idref="').Append(XmlEncode(FChapters[I].Id, True)).Append('"/>').Append(sLineBreak);
    SB.Append('  </spine>').Append(sLineBreak);

    if (FCoverChapterId <> '') or (FNavTitle <> '') then
    begin
      SB.Append('  <guide>').Append(sLineBreak);
      if FCoverChapterId <> '' then
      begin
        C := FindChapter(FCoverChapterId);
        if C <> nil then
          SB.Append('    <reference type="cover" title="Cover" href="')
            .Append(XmlEncode(StripOebps(C.Href), True)).Append('"/>').Append(sLineBreak);
      end;
      SB.Append('    <reference type="toc" title="Table of Contents" href="nav.xhtml"/>').Append(sLineBreak);
      SB.Append('  </guide>').Append(sLineBreak);
    end;

    SB.Append('</package>').Append(sLineBreak);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{------------------------------------------------------------------------------
  nav.xhtml / toc.ncx
------------------------------------------------------------------------------}

function TEpubGenerator.BuildNavList(AParentId: string; ALevel: Integer): string;
var
  SB: TStringBuilder;
  I: Integer;
  C: TEpubChapter;
  ChildResult: string;
  HasItems: Boolean;
begin
  SB := TStringBuilder.Create;
  try
    HasItems := False;
    for I := 0 to FChapters.Count - 1 do
    begin
      C := FChapters[I];
      if (not C.InToc) or (C.Level <> ALevel) or (C.ParentId <> AParentId) then
        Continue;
      if not HasItems then
      begin
        SB.Append('    <ol>').Append(sLineBreak);
        HasItems := True;
      end;
      SB.Append('      <li><a href="').Append(XmlEncode(StripOebps(C.Href), True)).Append('">')
        .Append(XmlEncode(C.Title)).Append('</a>').Append(sLineBreak);
      ChildResult := BuildNavList(C.Id, ALevel + 1);
      if ChildResult <> '' then
        SB.Append(ChildResult);
      SB.Append('      </li>').Append(sLineBreak);
    end;
    if HasItems then
      SB.Append('    </ol>').Append(sLineBreak);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TEpubGenerator.BuildNavXhtml: string;
var
  SB: TStringBuilder;
  I: Integer;
  A: TEpubAsset;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('<?xml version="1.0" encoding="UTF-8"?>').Append(sLineBreak);
    SB.Append('<!DOCTYPE html>').Append(sLineBreak);
    SB.Append('<html xmlns="').Append(XHTML_NS).Append('" xmlns:epub="')
      .Append(EPUB_OPS_NS).Append('" xml:lang="')
      .Append(XmlEncode(FMetadata.Language, True)).Append('">').Append(sLineBreak);
    SB.Append('<head>').Append(sLineBreak);
    SB.Append('  <title>').Append(XmlEncode(FNavTitle)).Append('</title>').Append(sLineBreak);
    SB.Append('  <meta charset="utf-8"/>').Append(sLineBreak);
    if FAutoLinkStyles then
      for I := 0 to FAssets.Count - 1 do
      begin
        A := FAssets[I];
        if A.Kind = akStyle then
          SB.Append('  <link rel="stylesheet" type="text/css" href="')
            .Append(XmlEncode(StripOebps(A.Href), True)).Append('"/>').Append(sLineBreak);
      end;
    SB.Append('</head>').Append(sLineBreak);
    SB.Append('<body>').Append(sLineBreak);
    SB.Append('  <nav epub:type="toc" id="toc">').Append(sLineBreak);
    SB.Append('    <h1>').Append(XmlEncode(FNavTitle)).Append('</h1>').Append(sLineBreak);
    SB.Append(BuildNavList('', 1));
    SB.Append('  </nav>').Append(sLineBreak);

    SB.Append('  <nav epub:type="landmarks" hidden="hidden">').Append(sLineBreak);
    SB.Append('    <h2>导览</h2>').Append(sLineBreak);
    SB.Append('    <ol>').Append(sLineBreak);
    if FCoverChapterId <> '' then
    begin
      SB.Append('      <li><a epub:type="cover" href="')
        .Append(XmlEncode(StripOebps(FindChapter(FCoverChapterId).Href), True)).Append('">封面</a></li>').Append(sLineBreak);
    end;
    SB.Append('      <li><a epub:type="toc" href="nav.xhtml">目录</a></li>').Append(sLineBreak);
    if FChapters.Count > 0 then
      SB.Append('      <li><a epub:type="bodymatter" href="')
        .Append(XmlEncode(StripOebps(FChapters[0].Href), True)).Append('">正文</a></li>').Append(sLineBreak);
    SB.Append('    </ol>').Append(sLineBreak);
    SB.Append('  </nav>').Append(sLineBreak);
    SB.Append('</body>').Append(sLineBreak);
    SB.Append('</html>').Append(sLineBreak);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TEpubGenerator.BuildNcxPoints(AParentId: string; ALevel: Integer;
  var APlayOrder: Integer): string;
var
  SB: TStringBuilder;
  I: Integer;
  C: TEpubChapter;
  ChildResult: string;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to FChapters.Count - 1 do
    begin
      C := FChapters[I];
      if (not C.InToc) or (C.Level <> ALevel) or (C.ParentId <> AParentId) then
        Continue;
      Inc(APlayOrder);
      SB.Append('    <navPoint id="navpoint-').Append(APlayOrder.ToString)
        .Append('" playOrder="').Append(APlayOrder.ToString).Append('">').Append(sLineBreak);
      SB.Append('      <navLabel><text>').Append(XmlEncode(C.Title)).Append('</text></navLabel>').Append(sLineBreak);
      SB.Append('      <content src="').Append(XmlEncode(StripOebps(C.Href), True)).Append('"/>').Append(sLineBreak);
      ChildResult := BuildNcxPoints(C.Id, ALevel + 1, APlayOrder);
      if ChildResult <> '' then
        SB.Append(ChildResult);
      SB.Append('    </navPoint>').Append(sLineBreak);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TEpubGenerator.BuildNcx: string;
var
  SB: TStringBuilder;
  PlayOrder, MaxDepth, I: Integer;
  Points: string;
begin
  SB := TStringBuilder.Create;
  try
    PlayOrder := 0;
    MaxDepth := 1;
    for I := 0 to FChapters.Count - 1 do
      if FChapters[I].InToc then
        MaxDepth := Max(MaxDepth, FChapters[I].Level);

    Points := BuildNcxPoints('', 1, PlayOrder);

    SB.Append('<?xml version="1.0" encoding="UTF-8"?>').Append(sLineBreak);
    SB.Append('<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" ')
      .Append('"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">').Append(sLineBreak);
    SB.Append('<ncx xmlns="').Append(NCX_NS).Append('" version="2005-1" xml:lang="')
      .Append(XmlEncode(FMetadata.Language, True)).Append('">').Append(sLineBreak);
    SB.Append('  <head>').Append(sLineBreak);
    SB.Append('    <meta name="dtb:uid" content="').Append(XmlEncode(FMetadata.Identifier, True)).Append('"/>').Append(sLineBreak);
    SB.Append('    <meta name="dtb:depth" content="').Append(MaxDepth.ToString).Append('"/>').Append(sLineBreak);
    SB.Append('    <meta name="dtb:totalPageCount" content="0"/>').Append(sLineBreak);
    SB.Append('    <meta name="dtb:maxPageNumber" content="0"/>').Append(sLineBreak);
    SB.Append('  </head>').Append(sLineBreak);
    SB.Append('  <docTitle><text>').Append(XmlEncode(FMetadata.Title)).Append('</text></docTitle>').Append(sLineBreak);
    SB.Append('  <navMap>').Append(sLineBreak);
    SB.Append(Points);
    SB.Append('  </navMap>').Append(sLineBreak);
    SB.Append('</ncx>').Append(sLineBreak);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{------------------------------------------------------------------------------
  打包
------------------------------------------------------------------------------}

procedure TEpubGenerator.AddTextEntry(AZip: TZipFile; const AArchiveName, AText: string;
  ACompression: TZipCompression);
var
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(AText);
  AZip.Add(Bytes, AArchiveName, ACompression);
end;

procedure TEpubGenerator.AddAssetEntry(AZip: TZipFile; AAsset: TEpubAsset);
begin
  if Length(AAsset.Data) > 0 then
    AZip.Add(AAsset.Data, AAsset.Href, zcDeflate)
  else
  begin
    if not TFile.Exists(AAsset.SourceFile) then
      raise EEpubError.CreateFmt('打包时找不到资源: %s', [AAsset.SourceFile]);
    AZip.Add(AAsset.SourceFile, AAsset.Href, zcDeflate);
  end;
end;

procedure TEpubGenerator.BuildPackage(AZip: TZipFile);
var
  I: Integer;
begin
  // 1. mimetype 必须是第一个条目且不压缩
  AddTextEntry(AZip, 'mimetype', 'application/epub+zip', zcStored);

  // 2. 容器与包文档
  AddTextEntry(AZip, 'META-INF/container.xml', BuildContainerXml);
  AddTextEntry(AZip, 'OEBPS/content.opf', BuildOpf);
  AddTextEntry(AZip, 'OEBPS/nav.xhtml', BuildNavXhtml);
  if FGenerateNCX then
    AddTextEntry(AZip, 'OEBPS/toc.ncx', BuildNcx);

  // 3. 静态资源
  for I := 0 to FAssets.Count - 1 do
    AddAssetEntry(AZip, FAssets[I]);

  // 4. 章节
  for I := 0 to FChapters.Count - 1 do
    AddTextEntry(AZip, FChapters[I].Href, BuildChapterDocument(FChapters[I]));
end;

procedure TEpubGenerator.SaveToFile(const AFileName: string);
var
  Zip: TZipFile;
  Dir: string;
begin
  Dir := ExtractFilePath(AFileName);
  if (Dir <> '') and (not TDirectory.Exists(Dir)) then
    TDirectory.CreateDirectory(Dir);

  Zip := TZipFile.Create;
  try
    Zip.Open(AFileName, zmWrite);
    try
      BuildPackage(Zip);
    finally
      Zip.Close;
    end;
  finally
    Zip.Free;
  end;
end;

procedure TEpubGenerator.SaveToStream(AStream: TStream);
var
  Zip: TZipFile;
begin
  AStream.Size := 0;
  AStream.Position := 0;
  Zip := TZipFile.Create;
  try
    Zip.Open(AStream, zmWrite);
    try
      BuildPackage(Zip);
    finally
      Zip.Close;
    end;
  finally
    Zip.Free;
  end;
end;

end.
