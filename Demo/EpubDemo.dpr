program EpubDemo;

{==============================================================================
  EpubDemo.dpr —— EpubGenerator.pas 的完整测试示例

  运行后会在 Output 目录生成 SampleBook.epub，包含：
    · 元数据（标题/作者/语言/出版信息/UUID）
    · 封面章节 + 三级目录层级（含子章节）
    · 内联 CSS 样式
    · PNG 封面图
    · 真实 MP3 音频（通过【audio:id】占位符嵌入）
    · 真实 MP4 视频（通过【video:id】占位符嵌入）
    · SMIL 媒体叠加（可选的高级音视频同步能力）
    · 同时生成 EPUB3 nav.xhtml 与 EPUB2 toc.ncx

  生成完毕后程序会重新打开 .epub 做结构自检并打印结果。
==============================================================================}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Zip,
  System.DateUtils,
  EpubGenerator in '..\EpubGenerator.pas';

var
  AppDir, AssetsDir, OutDir, OutFile: string;

procedure Say(const S: string);
begin
  WriteLn(S);
end;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    raise Exception.Create('自检失败: ' + AMessage);
  Say('  [OK] ' + AMessage);
end;

function ReadEntryText(AZip: TZipFile; const AName: string): string;
var
  Bytes: TBytes;
begin
  AZip.Read(AName, Bytes);
  Result := TEncoding.UTF8.GetString(Bytes);
end;

procedure GenerateSampleBook;
var
  G: TEpubGenerator;
  CoverChapter, Ch1, Ch2: TEpubChapter;
  Audio, Video, SmilRes: TEpubAsset;
  Smil: TBytes;
  SmilText: string;
begin
  G := TEpubGenerator.Create;
  try
    // ---------------- 元数据 ----------------
    G.Metadata.Title       := 'EPUB 音视频生成器演示';
    G.Metadata.Author      := 'Delphi 12.2';
    G.Metadata.AddAuthor('System.Zip');
    G.Metadata.Language    := 'zh-CN';
    G.Metadata.Publisher   := 'EpubGenerator 示例工程';
    G.Metadata.Description := '展示章节层级、封面、图片、音频、视频、SMIL 媒体叠加的完整示例。';
    G.Metadata.Subject     := 'EPUB 3.0, 音视频, Delphi';
    G.Metadata.Date        := FormatDateTime('yyyy-mm-dd', Now);
    G.Metadata.Rights      := '仅用于测试演示';
    G.Metadata.ModifiedUTC := TTimeZone.Local.ToUniversalTime(Now);
    G.GenerateNCX := True;
    G.NavTitle := '目录';

    // ---------------- 样式 ----------------
    G.AddStyleText('main.css',
      'body{font-family:"Microsoft YaHei",sans-serif;line-height:1.8;margin:5%;color:#222;}' + sLineBreak +
      'h1{color:#1a4d8f;border-bottom:2px solid #1a4d8f;padding-bottom:.3em;}' + sLineBreak +
      'h2{color:#2a6dbc;}' + sLineBreak +
      'img{max-width:100%;height:auto;display:block;margin:1em auto;}' + sLineBreak +
      'video,audio{max-width:100%;width:100%;margin:1em 0;}' + sLineBreak +
      'p{text-indent:2em;}' + sLineBreak);

    // ---------------- 图片 / 音频 / 视频 ----------------
    G.AddCoverImage(TPath.Combine(AssetsDir, 'cover.png'), 'cover.png');
    Audio := G.AddAudio(TPath.Combine(AssetsDir, 'sample.mp3'), 'narration.mp3', 'audio/mpeg');
    Video := G.AddVideo(TPath.Combine(AssetsDir, 'sample.mp4'), 'demo.mp4', 'video/mp4');
    Audio.Alt := '演示音频';
    Video.Alt := '演示视频';

    // ---------------- 章节 ----------------
    CoverChapter := G.AddChapter('封面',
      '<div style="text-align:center">' +
      G.ImageTag('../Images/cover.png', '示例封面') +
      '<h1>EPUB 音视频生成器演示</h1>' +
      '<p style="text-align:center">Delphi 12.2 + System.Zip</p></div>', 'cover.xhtml');
    CoverChapter.InToc := False;
    G.SetCoverChapter(CoverChapter);

    Ch1 := G.AddChapter('第一章 简介',
      '<h1>第一章 简介</h1>' +
      '<p>本书由 EpubGenerator.pas 在运行时生成，不依赖任何第三方库。</p>' +
      '<p>生成器负责打包 mimetype、container.xml、content.opf、nav.xhtml 和 toc.ncx。</p>' +
      '<p>图片资源通过占位符插入：' + G.ImageTag('../Images/cover.png', '封面缩略图') + '</p>',
      'chapter001.xhtml');

    Ch2 := G.AddChapter('第二章 音频',
      '<h1>第二章 音频</h1>' +
      '<p id="sentence1">下面的播放器嵌入了一段真实的 MP3 音频。</p>' +
      '{{audio:' + Audio.Id + '}}' + sLineBreak +
      '<p>音频资源在 OPF 中声明为 audio/mpeg，章节通过相对路径引用包内文件。</p>',
      'chapter002.xhtml');

    G.AddChapter('2.1 音频细节',
      '<h2>2.1 音频细节</h2>' +
      '<p>这是二级目录条目，父节点为“第二章 音频”，用于验证层级目录生成。</p>',
      2, Ch2.Id, 'chapter002_1.xhtml');

    G.AddChapter('第三章 视频',
      '<h1>第三章 视频</h1>' +
      '<p>下面嵌入一段真实的 MP4 视频（H.264 / AAC）。</p>' +
      '{{video:' + Video.Id + '}}' + sLineBreak +
      '<p>相关章节：' + '{{link:' + Ch1.Id + '}}</p>',
      'chapter003.xhtml');

    // ---------------- SMIL 媒体叠加（高级特性） ----------------
    SmilText := '<?xml version="1.0" encoding="UTF-8"?>' + sLineBreak +
      '<smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">' + sLineBreak +
      '  <body>' + sLineBreak +
      '    <par id="par1">' + sLineBreak +
      '      <text src="../Text/chapter002.xhtml#sentence1"/>' + sLineBreak +
      '      <audio src="../Media/narration.mp3" clipBegin="0s" clipEnd="5s"/>' + sLineBreak +
      '    </par>' + sLineBreak +
      '  </body>' + sLineBreak +
      '</smil>' + sLineBreak;
    Smil := TEncoding.UTF8.GetBytes(SmilText);
    SmilRes := G.AddBytesAsset('chapter002.smil', 'application/smil+xml', Smil, akSmil);
    Ch2.MediaOverlayId := SmilRes.Id;

    // ---------------- 输出 ----------------
    G.SaveToFile(OutFile);
    Say('  已生成: ' + OutFile);
  finally
    G.Free;
  end;
end;

procedure VerifyEpub;
var
  Zip: TZipFile;
  Names: TArray<string>;
  I: Integer;
  Mime: string;
  Opf, Nav, Ncx, Ch2: string;
  Found: Boolean;
begin
  Say('');
  Say('开始自检生成的 EPUB ...');

  Check(TZipFile.IsValid(OutFile), '压缩包是合法的 ZIP/EPUB 容器');

  Zip := TZipFile.Create;
  try
    Zip.Open(OutFile, zmRead);
    try
      Names := Zip.FileNames;
      Check(Length(Names) > 0, '压缩包内至少有 1 个条目');
      Check(Names[0] = 'mimetype', '第一个条目是 mimetype');
      Check(Zip.FileInfo[0].CompressionMethod = 0, 'mimetype 未压缩（STORED）');

      Mime := ReadEntryText(Zip, 'mimetype');
      Check(Trim(Mime) = 'application/epub+zip', 'mimetype 内容正确');

      Found := False;
      for I := 0 to High(Names) do
        if Names[I] = 'META-INF/container.xml' then Found := True;
      Check(Found, '包含 META-INF/container.xml');

      Found := False;
      for I := 0 to High(Names) do
        if Names[I] = 'OEBPS/content.opf' then Found := True;
      Check(Found, '包含 OEBPS/content.opf');

      Opf := ReadEntryText(Zip, 'OEBPS/content.opf');
      Check(Pos('version="3.0"', Opf) > 0, 'OPF 声明 EPUB 3.0');
      Check(Pos('media-type="audio/mpeg"', Opf) > 0, 'OPF 声明音频 MIME');
      Check(Pos('media-type="video/mp4"', Opf) > 0, 'OPF 声明视频 MIME');
      Check(Pos('application/smil+xml', Opf) > 0, 'OPF 声明 SMIL 媒体叠加');
      Check(Pos('properties="cover-image"', Opf) > 0, '封面图带 cover-image 属性');
      Check(Pos('dcterms:modified', Opf) > 0, '包含必需的 dcterms:modified');

      Nav := ReadEntryText(Zip, 'OEBPS/nav.xhtml');
      Check(Pos('epub:type="toc"', Nav) > 0, 'nav.xhtml 包含 toc 导航');
      Check(Pos('2.1 音频细节', Nav) > 0, 'nav.xhtml 包含子章节');

      Ncx := ReadEntryText(Zip, 'OEBPS/toc.ncx');
      Check(Pos('navPoint', Ncx) > 0, 'toc.ncx 包含 navPoint');

      Ch2 := ReadEntryText(Zip, 'OEBPS/Text/chapter002.xhtml');
      Check(Pos('<audio src="../Media/narration.mp3"', Ch2) > 0, '音频占位符已展开为 audio 标签');
      Check(Pos('media-overlay="../Misc/chapter002.smil"', Ch2) > 0, '章节关联 SMIL 媒体叠加');

      Found := False;
      for I := 0 to High(Names) do
        if Names[I] = 'OEBPS/Media/demo.mp4' then
          Found := Zip.FileInfo[I].CompressedSize > 0;
      Check(Found, '视频文件已写入且非空');

      Found := False;
      for I := 0 to High(Names) do
        if Names[I] = 'OEBPS/Media/narration.mp3' then
          Found := Zip.FileInfo[I].CompressedSize > 0;
      Check(Found, '音频文件已写入且非空');

      Say('');
      Say('包内条目（共 ' + Length(Names).ToString + ' 个）：');
      for I := 0 to High(Names) do
        Say('  ' + Names[I]);

      Say('');
      Say('全部自检通过。');
    finally
      Zip.Close;
    end;
  finally
    Zip.Free;
  end;
end;

begin
  try
    AppDir := ExtractFilePath(ParamStr(0));
    AssetsDir := TPath.GetFullPath(TPath.Combine(AppDir, '..\TestAssets'));
    OutDir := TPath.GetFullPath(TPath.Combine(AppDir, '..\Output'));
    OutFile := TPath.Combine(OutDir, 'SampleBook.epub');

    if not TDirectory.Exists(AssetsDir) then
      raise Exception.Create('找不到测试素材目录: ' + AssetsDir);
    if not TFile.Exists(TPath.Combine(AssetsDir, 'sample.mp3')) or
       not TFile.Exists(TPath.Combine(AssetsDir, 'sample.mp4')) or
       not TFile.Exists(TPath.Combine(AssetsDir, 'cover.png')) then
      raise Exception.Create('测试素材不完整（需要 sample.mp3 / sample.mp4 / cover.png）');

    Say('=== Delphi 12.2 EPUB 生成器测试示例 ===');
    Say('素材目录: ' + AssetsDir);
    Say('输出文件: ' + OutFile);
    Say('');

    GenerateSampleBook;
    VerifyEpub;

    Say('');
    Say('完成。');
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, '错误: ' + E.Message);
      Halt(1);
    end;
  end;
end.
