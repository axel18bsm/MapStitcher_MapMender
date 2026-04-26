unit UFileIO;

{$mode objfpc}{$H+}

// ============================================================
//  UFileIO - Chargement / Sauvegarde / Navigateur de fichiers
//
//  Contenu :
//    - Navigateur de repertoires en mode raylib (DrawFileBrowser,
//      HandleFileBrowserInput)
//    - Dialog de choix de role (GAUCHE / CENTRALE / DROITE)
//    - LoadMapCard   : charge un PNG en TImage + TTexture2D
//    - SaveMergedImage : fusionne les 3 cartes et exporte en PNG
// ============================================================

interface

uses
  raylib, UGlobals, SysUtils,Math;

// --- Etat interne du navigateur ---
type
  TBrowserState = (bsBrowsing, bsRoleSelect);

  TFileEntry = record
    Name     : String;
    IsDir    : Boolean;
    FullPath : String;
  end;

var
  BrowserState    : TBrowserState;
  BrowserDir      : String;
  FileList        : array of TFileEntry;
  FileCount       : Integer;
  BrowserScroll   : Integer;
  BrowserHovered  : Integer;
  PendingFilePath : String;    // PNG en attente d attribution de role

// --- Interface publique ---
procedure InitFileBrowser(const AStartDir: String);
procedure RefreshFileList;
procedure HandleFileBrowserInput;
procedure DrawFileBrowser;

procedure LoadMapCard(const APath: String; ARole: TMapRole);
procedure SaveMergedImage(const ADestPath: String);

implementation

// ============================================================
//  Constantes de mise en page du navigateur
// ============================================================
const
  BR_X        = 40;     // panneau gauche : X
  BR_Y        = 40;     // panneau gauche : Y
  BR_W        = 620;    // largeur du panneau
  BR_H        = 620;    // hauteur du panneau
  LINE_H      = 26;     // hauteur d une ligne d entree
  HEADER_H    = 56;     // hauteur de l en-tete (chemin courant)
  MAX_VISIBLE = 21;     // nombre de lignes visibles en meme temps

  // Panneau d information a droite
  INFO_X = 700;
  INFO_Y = 40;

  // Dialog choix du role
  DLG_X  = 180;
  DLG_Y  = 260;
  DLG_W  = 920;
  DLG_H  = 200;
  BTN_W  = 150;
  BTN_H  = 48;

// ============================================================
//  Helpers couleur (evite les initialisations inline non portables)
// ============================================================
function MakeColor(R, G, B, A: Byte): TColor;
begin
  Result.r := R;
  Result.g := G;
  Result.b := B;
  Result.a := A;
end;

// ============================================================
//  InitFileBrowser
// ============================================================
procedure InitFileBrowser(const AStartDir: String);
begin
  if AStartDir = '' then
    BrowserDir := GetCurrentDir + PathDelim
  else
    BrowserDir := IncludeTrailingPathDelimiter(AStartDir);

  BrowserScroll   := 0;
  BrowserHovered  := -1;
  BrowserState    := bsBrowsing;
  PendingFilePath := '';
  RefreshFileList;
end;

// ============================================================
//  RefreshFileList  - lit le repertoire courant
// ============================================================
procedure RefreshFileList;
var
  SR  : TSearchRec;
  Idx : Integer;
  Par : String;
begin
  Idx := 0;
  SetLength(FileList, 256);   // pre-allouer, on redimensionne ensuite

  // Entree ".." pour remonter d un niveau
  Par := ExtractFilePath(ExcludeTrailingPathDelimiter(BrowserDir));
  if Par = '' then Par := BrowserDir;
  FileList[Idx].Name     := '..  [dossier parent]';
  FileList[Idx].IsDir    := True;
  FileList[Idx].FullPath := Par;
  Inc(Idx);

  // Sous-repertoires
  if FindFirst(BrowserDir + '*', faDirectory, SR) = 0 then
  begin
    repeat
      if ((SR.Attr and faDirectory) <> 0) and
         (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        if Idx >= Length(FileList) then
          SetLength(FileList, Length(FileList) + 64);
        FileList[Idx].Name     := '[D]  ' + SR.Name;
        FileList[Idx].IsDir    := True;
        FileList[Idx].FullPath := BrowserDir + SR.Name + PathDelim;
        Inc(Idx);
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;

  // Fichiers PNG uniquement
  if FindFirst(BrowserDir + '*.png', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
      begin
        if Idx >= Length(FileList) then
          SetLength(FileList, Length(FileList) + 64);
        FileList[Idx].Name     := SR.Name;
        FileList[Idx].IsDir    := False;
        FileList[Idx].FullPath := BrowserDir + SR.Name;
        Inc(Idx);
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;

  FileCount := Idx;
  SetLength(FileList, FileCount);
  BrowserScroll  := 0;
  BrowserHovered := -1;
end;

// ============================================================
//  HandleFileBrowserInput
// ============================================================
procedure HandleFileBrowserInput;
var
  MousePos  : TVector2;
  WheelMove : Single;
  I, LineY  : Integer;
  MaxScroll : Integer;
  Clicked   : Integer;
  BtnY      : Integer;

  procedure TrySelectRole(ARole: TMapRole);
  begin
    LoadMapCard(PendingFilePath, ARole);
    BrowserState := bsBrowsing;
    // Toutes les 3 cartes chargees → on passe en edition
    if Maps[mrLeft].Loaded and
       Maps[mrCenter].Loaded and
       Maps[mrRight].Loaded then
      AppState := asEditing;
  end;

begin
  MousePos := GetMousePosition;

  // ---------------------------------------------------------
  //  Mode navigation dans le repertoire
  // ---------------------------------------------------------
  if BrowserState = bsBrowsing then
  begin
    // Scroll molette
    WheelMove := GetMouseWheelMove;
    if WheelMove <> 0 then
    begin
      BrowserScroll := BrowserScroll - Round(WheelMove * 3);
      MaxScroll := FileCount - MAX_VISIBLE;
      if MaxScroll < 0 then MaxScroll := 0;
      if BrowserScroll < 0 then BrowserScroll := 0;
      if BrowserScroll > MaxScroll then BrowserScroll := MaxScroll;
    end;

    // Mise a jour du survol
    BrowserHovered := -1;
    Clicked        := -1;

    for I := 0 to MAX_VISIBLE - 1 do
    begin
      if (BrowserScroll + I) >= FileCount then Break;
      LineY := BR_Y + HEADER_H + I * LINE_H;

      if (MousePos.x >= BR_X) and (MousePos.x <= BR_X + BR_W) and
         (MousePos.y >= LineY) and (MousePos.y < LineY + LINE_H) then
      begin
        BrowserHovered := BrowserScroll + I;
        if IsMouseButtonPressed(MOUSE_BUTTON_LEFT) then
          Clicked := BrowserScroll + I;
        Break;
      end;
    end;

    if Clicked >= 0 then
    begin
      if FileList[Clicked].IsDir then
      begin
        BrowserDir := FileList[Clicked].FullPath;
        RefreshFileList;
      end
      else
      begin
        PendingFilePath := FileList[Clicked].FullPath;
        BrowserState    := bsRoleSelect;
      end;
    end;
  end

  // ---------------------------------------------------------
  //  Mode choix du role
  // ---------------------------------------------------------
  else if BrowserState = bsRoleSelect then
  begin
    if IsMouseButtonPressed(MOUSE_BUTTON_LEFT) then
    begin
      BtnY := DLG_Y + 110;

      // Bouton GAUCHE  (1er tiers)
      if (MousePos.x >= DLG_X + 50)  and (MousePos.x <= DLG_X + 50  + BTN_W) and
         (MousePos.y >= BtnY)         and (MousePos.y <= BtnY + BTN_H) then
        TrySelectRole(mrLeft);

      // Bouton CENTRALE (tiers central)
      if (MousePos.x >= DLG_X + 385) and (MousePos.x <= DLG_X + 385 + BTN_W) and
         (MousePos.y >= BtnY)         and (MousePos.y <= BtnY + BTN_H) then
        TrySelectRole(mrCenter);

      // Bouton DROITE   (dernier tiers)
      if (MousePos.x >= DLG_X + 720) and (MousePos.x <= DLG_X + 720 + BTN_W) and
         (MousePos.y >= BtnY)         and (MousePos.y <= BtnY + BTN_H) then
        TrySelectRole(mrRight);

      // Bouton ANNULER
      if (MousePos.x >= DLG_X + DLG_W - 100) and
         (MousePos.x <= DLG_X + DLG_W - 10)  and
         (MousePos.y >= DLG_Y + 10) and
         (MousePos.y <= DLG_Y + 30) then
        BrowserState := bsBrowsing;
    end;
  end;
end;

// ============================================================
//  DrawFileBrowser
// ============================================================
procedure DrawFileBrowser;
var
  I, LineY      : Integer;
  LineColor     : TColor;
  TxtColor      : TColor;
  R             : TMapRole;
  RoleLabel     : array[TMapRole] of String;
  StatusStr     : String;
  BtnY, BtnX    : Integer;
  BtnColor      : TColor;
  AllLoaded     : Boolean;
begin
  RoleLabel[mrLeft]   := 'GAUCHE';
  RoleLabel[mrCenter] := 'CENTRALE';
  RoleLabel[mrRight]  := 'DROITE';

  // -------------------------------------------------------
  //  Fond general de la fenetre
  // -------------------------------------------------------
  DrawRectangle(0, 0, ScreenWidth, ScreenHeight,
                MakeColor(20, 20, 30, 255));

  // -------------------------------------------------------
  //  Navigateur de fichiers (colonne gauche)
  // -------------------------------------------------------
  if BrowserState = bsBrowsing then
  begin
    // Cadre externe
    DrawRectangle(BR_X - 2, BR_Y - 2, BR_W + 4, BR_H + 4,
                  MakeColor(80, 80, 100, 255));
    DrawRectangle(BR_X, BR_Y, BR_W, BR_H, MakeColor(15, 15, 20, 255));

    // En-tete : chemin courant
    DrawRectangle(BR_X, BR_Y, BR_W, HEADER_H, MakeColor(40, 40, 60, 255));
    DrawText('Dossier :', BR_X + 8, BR_Y + 6, 14, LIGHTGRAY);
    DrawText(PChar(BrowserDir), BR_X + 8, BR_Y + 26, 13, WHITE);
    DrawLine(BR_X, BR_Y + HEADER_H - 1, BR_X + BR_W, BR_Y + HEADER_H - 1,
             MakeColor(80, 80, 120, 255));

    // Lignes de fichiers
    for I := 0 to MAX_VISIBLE - 1 do
    begin
      if (BrowserScroll + I) >= FileCount then Break;
      LineY := BR_Y + HEADER_H + I * LINE_H;

      // Fond de ligne
      if (BrowserScroll + I) = BrowserHovered then
        LineColor := MakeColor(60, 70, 130, 255)
      else if (I mod 2) = 0 then
        LineColor := MakeColor(22, 22, 30, 255)
      else
        LineColor := MakeColor(18, 18, 26, 255);

      DrawRectangle(BR_X, LineY, BR_W, LINE_H, LineColor);

      // Texte de l entree
      if FileList[BrowserScroll + I].IsDir then
      begin
        DrawText(PChar(FileList[BrowserScroll + I].Name),
                 BR_X + 10, LineY + 5, 14, YELLOW);
      end
      else
      begin
        // Verifier si cette carte est deja chargee
        TxtColor := WHITE;
        for R := mrLeft to mrRight do
          if Maps[R].Loaded and
             (Maps[R].FilePath = FileList[BrowserScroll + I].FullPath) then
            TxtColor := MakeColor(100, 220, 100, 255);

        DrawText(PChar(FileList[BrowserScroll + I].Name),
                 BR_X + 10, LineY + 5, 14, TxtColor);
      end;
    end;

    // Barre de defilement indicative
    if FileCount > MAX_VISIBLE then
    begin
      DrawRectangle(BR_X + BR_W - 6, BR_Y + HEADER_H,
                    6, BR_H - HEADER_H, MakeColor(40, 40, 50, 255));
      DrawRectangle(
        BR_X + BR_W - 6,
        BR_Y + HEADER_H + Round((BR_H - HEADER_H) * BrowserScroll / FileCount),
        6,
        Round((BR_H - HEADER_H) * MAX_VISIBLE / FileCount),
        MakeColor(120, 120, 180, 255));
    end;

    // -------------------------------------------------------
    //  Panneau d etat a droite
    // -------------------------------------------------------
    DrawText('Cartes a charger :', INFO_X, INFO_Y, 20, WHITE);
    DrawLine(INFO_X, INFO_Y + 26, INFO_X + 480, INFO_Y + 26,
             MakeColor(80, 80, 100, 255));

    AllLoaded := True;
    for R := mrLeft to mrRight do
    begin
      if Maps[R].Loaded then
      begin
        StatusStr := '  [OK]  ' + RoleLabel[R] + ' : ' +
                     ExtractFileName(Maps[R].FilePath);
        DrawText(PChar(StatusStr), INFO_X, INFO_Y + 40 + Ord(R) * 36, 15,
                 MakeColor(80, 220, 80, 255));
      end
      else
      begin
        StatusStr := '  [ ]   ' + RoleLabel[R] + ' : (non chargee)';
        DrawText(PChar(StatusStr), INFO_X, INFO_Y + 40 + Ord(R) * 36, 15,
                 MakeColor(160, 160, 160, 255));
        AllLoaded := False;
      end;
    end;

    DrawText('Cliquez sur un PNG pour l assigner.',
             INFO_X, INFO_Y + 160, 14, LIGHTGRAY);
    DrawText('Cliquez sur [D] pour entrer dans un dossier.',
             INFO_X, INFO_Y + 180, 14, LIGHTGRAY);
    DrawText('Molette pour faire defiler.',
             INFO_X, INFO_Y + 200, 14, LIGHTGRAY);

    if AllLoaded then
    begin
      DrawRectangle(INFO_X, INFO_Y + 240, 400, 50,
                    MakeColor(40, 160, 40, 255));
      DrawRectangleLines(INFO_X, INFO_Y + 240, 400, 50, WHITE);
      DrawText('Toutes les cartes sont chargees !',
               INFO_X + 12, INFO_Y + 256, 16, WHITE);
      DrawText('Elles vont s ouvrir en mode edition...',
               INFO_X + 12, INFO_Y + 275, 13, LIGHTGRAY);
    end;
  end

  // -------------------------------------------------------
  //  Dialog de choix du role
  // -------------------------------------------------------
  else if BrowserState = bsRoleSelect then
  begin
    // Fond semi-transparent
    DrawRectangle(0, 0, ScreenWidth, ScreenHeight,
                  MakeColor(0, 0, 0, 160));

    // Boite du dialog
    DrawRectangle(DLG_X, DLG_Y, DLG_W, DLG_H, MakeColor(30, 30, 50, 255));
    DrawRectangleLines(DLG_X, DLG_Y, DLG_W, DLG_H, WHITE);

    DrawText('Quel role pour cette carte ?',
             DLG_X + 20, DLG_Y + 14, 22, WHITE);
    DrawText(PChar('Fichier : ' + ExtractFileName(PendingFilePath)),
             DLG_X + 20, DLG_Y + 44, 14, LIGHTGRAY);
    DrawText('[Annuler]', DLG_X + DLG_W - 95, DLG_Y + 14, 14,
             MakeColor(200, 100, 100, 255));

    // Les 3 boutons de role
    BtnY := DLG_Y + 110;

    // GAUCHE
    BtnX     := DLG_X + 50;
    BtnColor := MakeColor(50, 80, 180, 255);
    DrawRectangle(BtnX, BtnY, BTN_W, BTN_H, BtnColor);
    DrawRectangleLines(BtnX, BtnY, BTN_W, BTN_H, WHITE);
    DrawText('GAUCHE', BtnX + 18, BtnY + 14, 20, WHITE);

    // CENTRALE
    BtnX     := DLG_X + 385;
    BtnColor := MakeColor(180, 60, 60, 255);
    DrawRectangle(BtnX, BtnY, BTN_W, BTN_H, BtnColor);
    DrawRectangleLines(BtnX, BtnY, BTN_W, BTN_H, WHITE);
    DrawText('CENTRALE', BtnX + 8, BtnY + 14, 20, WHITE);

    // DROITE
    BtnX     := DLG_X + 720;
    BtnColor := MakeColor(40, 150, 50, 255);
    DrawRectangle(BtnX, BtnY, BTN_W, BTN_H, BtnColor);
    DrawRectangleLines(BtnX, BtnY, BTN_W, BTN_H, WHITE);
    DrawText('DROITE', BtnX + 18, BtnY + 14, 20, WHITE);
  end;
end;

// ============================================================
//  LoadMapCard  - charge un PNG en image CPU + texture GPU
// ============================================================
procedure LoadMapCard(const APath: String; ARole: TMapRole);
var
  Img : TImage;
begin
  // Liberer l ancienne texture si elle existait
  if Maps[ARole].Loaded then
  begin
    UnloadTexture(Maps[ARole].Texture);
    UnloadImage(Maps[ARole].Image);
  end;

  // Charger l image en RAM (pour les calculs pixel)
  Img := LoadImage(PChar(APath));

  // Convertir en RGBA32 pour garantir un format uniforme
  ImageFormat(@Img, PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);

  Maps[ARole].Image    := Img;
  Maps[ARole].Texture  := LoadTextureFromImage(Img);
  Maps[ARole].Width    := Img.width;
  Maps[ARole].Height   := Img.height;
  Maps[ARole].FilePath := APath;
  Maps[ARole].Role     := ARole;
  Maps[ARole].Loaded   := True;

  // Positionnement initial automatique selon le role
  case ARole of
    mrLeft :
      begin
        Maps[ARole].Position.x := 0;
        Maps[ARole].Position.y := 0;
        Maps[ARole].Alpha      := 1.0;
      end;
    mrCenter :
      begin
        // Placement a mi-chemin de la carte gauche si elle existe
        if Maps[mrLeft].Loaded then
          Maps[ARole].Position.x := Maps[mrLeft].Width * 0.5
        else
          Maps[ARole].Position.x := 0;
        Maps[ARole].Position.y := 0;
        Maps[ARole].Alpha      := CENTER_ALPHA_DEFAULT;
      end;
    mrRight :
      begin
        // Placement apres la carte gauche si elle existe
        if Maps[mrLeft].Loaded then
          Maps[ARole].Position.x := Maps[mrLeft].Width * 0.85
        else
          Maps[ARole].Position.x := 400;
        Maps[ARole].Position.y := 0;
        Maps[ARole].Alpha      := 1.0;
      end;
  end;
end;

// ============================================================
//  SaveMergedImage  - fusionne les 3 cartes → PNG
//
//  Priorite : mrCenter en premier, puis mrLeft, puis mrRight.
//  Pour chaque pixel du rectangle (ExportP1 → ExportP2),
//  on cherche la premiere carte qui couvre ce point monde.
// ============================================================
// ============================================================
//  PixelForWorld
//  Retourne la couleur du pixel monde (WX, WY) en appliquant
//  la regle de priorite :
//    - Si InBand = True  → Centre d abord, puis Gauche, puis Droite
//    - Si InBand = False → Gauche d abord, puis Droite, puis Centre
//  En cas d absence totale de carte, retourne Blanc.
// ============================================================
function PixelForWorld(WX, WY: Integer; InBand: Boolean): TColor;
const
  PRIO_BAND    : array[0..2] of TMapRole = (mrCenter, mrLeft, mrRight);
  PRIO_OUTSIDE : array[0..2] of TMapRole = (mrLeft, mrRight, mrCenter);
var
  PI   : Integer;
  R    : TMapRole;
  MapX : Integer;
  MapY : Integer;
begin
  Result := WHITE;
  for PI := 0 to 2 do
  begin
    if InBand then R := PRIO_BAND[PI]
              else R := PRIO_OUTSIDE[PI];

    if not Maps[R].Loaded then Continue;

    MapX := WX - Round(Maps[R].Position.x);
    MapY := WY - Round(Maps[R].Position.y);

    if (MapX >= 0) and (MapX < Maps[R].Width) and
       (MapY >= 0) and (MapY < Maps[R].Height) then
    begin
      Result := GetImageColor(Maps[R].Image, MapX, MapY);
      Exit;
    end;
  end;
end;

// ============================================================
//  SaveMergedImage
//  Sauvegarde 2 fichiers PNG a l echelle 1:1 :
//
//  1. ADestPath                 → carte totale (ExportP1..ExportP2)
//     Regle de fusion :
//       Dans la bande (BandP1..BandP2) → Centre prioritaire
//       Hors bande                     → Gauche/Droite prioritaires
//
//  2. ADestPath sans extension + '_band.png'
//     → uniquement la bande de priorite (BandP1..BandP2)
//     avec la meme regle (Centre prioritaire)
// ============================================================
procedure SaveMergedImage(const ADestPath: String);
var
  // Coordonnees normalisees (min/max) pour eviter l inversion haut/bas
  Ex1X, Ex1Y, Ex2X, Ex2Y   : Integer;  // export total
  Bx1X, Bx1Y, Bx2X, Bx2Y  : Integer;  // bande
  OutW, OutH               : Integer;
  BandW, BandH             : Integer;
  OutImg                   : TImage;
  BandImg                  : TImage;
  X, Y                     : Integer;
  WX, WY                   : Integer;
  InBand                   : Boolean;
  BandPath                 : String;
begin
  // --- Normaliser les 4 coins (ordre min/max independamment du sens du clic) ---
  Ex1X := Round(Min(ExportP1.x, ExportP2.x));
  Ex1Y := Round(Min(ExportP1.y, ExportP2.y));
  Ex2X := Round(Max(ExportP1.x, ExportP2.x));
  Ex2Y := Round(Max(ExportP1.y, ExportP2.y));

  Bx1X := Round(Min(BandP1.x, BandP2.x));
  Bx1Y := Round(Min(BandP1.y, BandP2.y));
  Bx2X := Round(Max(BandP1.x, BandP2.x));
  Bx2Y := Round(Max(BandP1.y, BandP2.y));

  OutW  := Ex2X - Ex1X;
  OutH  := Ex2Y - Ex1Y;
  BandW := Bx2X - Bx1X;
  BandH := Bx2Y - Bx1Y;

  if (OutW <= 0) or (OutH <= 0) then Exit;

  // -------------------------------------------------------
  //  PNG 1 : carte totale avec regle bande/hors-bande
  // -------------------------------------------------------
  OutImg := GenImageColor(OutW, OutH, WHITE);

  for Y := 0 to OutH - 1 do
  begin
    WY := Ex1Y + Y;
    for X := 0 to OutW - 1 do
    begin
      WX := Ex1X + X;

      // Le pixel est-il dans la bande de priorite ?
      InBand := BandP1Set and BandP2Set and
                (WX >= Bx1X) and (WX < Bx2X) and
                (WY >= Bx1Y) and (WY < Bx2Y);

      ImageDrawPixel(@OutImg, X, Y, PixelForWorld(WX, WY, InBand));
    end;
  end;

  ExportImage(OutImg, PChar(ADestPath));
  UnloadImage(OutImg);
  LastSavedPath := ADestPath;

  // -------------------------------------------------------
  //  PNG 2 : bande seule (Centre toujours prioritaire)
  // -------------------------------------------------------
  if (BandW > 0) and (BandH > 0) and BandP1Set and BandP2Set then
  begin
    BandImg  := GenImageColor(BandW, BandH, WHITE);

    for Y := 0 to BandH - 1 do
    begin
      WY := Bx1Y + Y;
      for X := 0 to BandW - 1 do
      begin
        WX := Bx1X + X;
        ImageDrawPixel(@BandImg, X, Y, PixelForWorld(WX, WY, True));
      end;
    end;

    // Chemin : meme nom que le fichier principal + '_band'
    BandPath := ChangeFileExt(ADestPath, '') + '_band.png';
    ExportImage(BandImg, PChar(BandPath));
    UnloadImage(BandImg);
  end;
end;

end.
