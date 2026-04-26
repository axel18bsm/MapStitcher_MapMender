unit UEvents;

{$mode objfpc}{$H+}

// ============================================================
//  UEvents - Interface graphique et gestion des evenements
//
//  Contenu :
//    HandleEvents : lecture clavier, souris, zoom, pan.
//                   Gere les transitions d etat (asFileSelect,
//                   asEditing, asExportSelect).
//    DrawScene    : rendu des 3 cartes + heatmap + selection
//                   + rubber-band du rectangle d export.
//    DrawUI       : barre d information en bas de l ecran,
//                   score de correspondance, raccourcis.
//
//  Raccourcis clavier resumes :
//    Fleches          Deplacer la carte selectionnee (1px)
//    Shift + Fleches  Deplacer x10
//    Tab              Cycler la selection entre les cartes
//    H                Activer / desactiver la heatmap
//    PgUp / PgDn      Augmenter / diminuer l alpha de la centrale
//    E                Passer en mode selection export (4 clics)
//    Entree           Confirmer et sauvegarder (apres les 4 clics)
//    Echap            Annuler / recommencer le mode export
//    F5               Forcer le recalcul de la heatmap
//    F1               Revenir au chargement des fichiers
//    + / -            Augmenter / diminuer la tolerance derive (5%)
//    Clic droit drag  Panoramique (pan)
//    Molette          Zoom autour du curseur
//    Clic gauche      Selectionner une carte (ou poser P1/P2)
// ============================================================

interface

uses
  raylib, UGlobals, UCalc, UFileIO, SysUtils, Math;

// --- Interface publique ---
procedure HandleEvents;
procedure DrawScene;
procedure DrawUI;

implementation

// ============================================================
//  Constantes de mise en page
// ============================================================
const
  UI_BAR_H = 90;    // hauteur de la barre d info en bas de l ecran

// ============================================================
//  Variables privees a UEvents
// ============================================================
var
  IsPanning      : Boolean;    // True pendant un drag clic droit
  PanLastPos     : TVector2;   // derniere position souris lors du pan
  ShowHeatmap    : Boolean;    // affichage heatmap on/off (touche H)
  ExportMousePos : TVector2;   // position monde courante en mode export
                               // (pour le rubber-band)
  SavedMessage   : String;     // texte du message de confirmation
  SavedMsgTimer  : Single;     // secondes restantes pour l afficher

// ============================================================
//  MakeColor
//  Helper local pour creer un TColor a partir de 4 composantes.
//  Evite les initialisations inline de records non portables.
// ============================================================
function MakeColor(R, G, B, A: Byte): TColor;
begin
  Result.r := R;
  Result.g := G;
  Result.b := B;
  Result.a := A;
end;

// ============================================================
//  MakeRect
//  Helper local pour creer un TRectangle.
// ============================================================
function MakeRect(X, Y, W, H: Single): TRectangle;
begin
  Result.x      := X;
  Result.y      := Y;
  Result.width  := W;
  Result.height := H;
end;

// ============================================================
//  AutoSavePath
//  Genere un nom de fichier de sortie dans le meme dossier que
//  la carte centrale (ou gauche si centrale absente).
//  Format : merged_YYYYMMDD_HHMMSS.png
// ============================================================
function AutoSavePath: String;
var
  BaseDir : String;
begin
  if Maps[mrCenter].Loaded then
    BaseDir := ExtractFilePath(Maps[mrCenter].FilePath)
  else if Maps[mrLeft].Loaded then
    BaseDir := ExtractFilePath(Maps[mrLeft].FilePath)
  else
    BaseDir := GetCurrentDir + PathDelim;

  Result := BaseDir + 'merged_' +
            FormatDateTime('YYYYMMDD_HHMMSS', Now) + '.png';
end;

// ============================================================
//  MapAtScreenPos
//  Cherche quelle carte se trouve sous la position ecran SPos.
//  Priorite : Center > Left > Right (la centrale est toujours
//  cliquable en premier car elle est dessinee au-dessus).
//  Retourne True et remplit Role si une carte est trouvee.
// ============================================================
function MapAtScreenPos(const SPos: TVector2; out Role: TMapRole): Boolean;
const
  CHECK_ORDER : array[0..2] of TMapRole = (mrCenter, mrLeft, mrRight);
var
  WPos : TVector2;
  I    : Integer;
  R    : TMapRole;
  LX, LY : Single;   // coordonnees locales dans la carte
begin
  Result := False;
  WPos   := ScreenToWorld(SPos);

  for I := 0 to 2 do
  begin
    R := CHECK_ORDER[I];
    if not Maps[R].Loaded then Continue;

    // Coordonnees du point dans le repere local de la carte
    LX := WPos.x - Maps[R].Position.x;
    LY := WPos.y - Maps[R].Position.y;

    // Le point est-il dans les limites de l image ?
    if (LX >= 0) and (LX < Maps[R].Width) and
       (LY >= 0) and (LY < Maps[R].Height) then
    begin
      Role   := R;
      Result := True;
      Exit;
    end;
  end;
end;

// ============================================================
//  HandleZoomAroundCursor
//  Applique un facteur de zoom en gardant le meme point monde
//  sous le curseur.
//  Formule :
//    worldUnderCursor = ScreenToWorld(mousePos)   (avant zoom)
//    ViewZoom *= factor
//    ViewOffset = mousePos - worldUnderCursor * ViewZoom
// ============================================================
procedure HandleZoomAroundCursor(const MousePos: TVector2;
                                 ZoomFactor: Single);
var
  WBefore : TVector2;
begin
  WBefore  := ScreenToWorld(MousePos);
  ViewZoom := ViewZoom * ZoomFactor;

  // Clamper entre les limites definies dans UGlobals
  if ViewZoom < ZOOM_MIN then ViewZoom := ZOOM_MIN;
  if ViewZoom > ZOOM_MAX then ViewZoom := ZOOM_MAX;

  // Recaler l offset pour conserver le point monde sous le curseur
  ViewOffset.x := MousePos.x - WBefore.x * ViewZoom;
  ViewOffset.y := MousePos.y - WBefore.y * ViewZoom;
end;

// ============================================================
//  HandleEvents  (appelee chaque frame depuis le .lpr)
// ============================================================
procedure HandleEvents;
var
  MousePos    : TVector2;
  WheelMove   : Single;
  MoveStep    : Integer;
  ClickedRole : TMapRole;
  SavePath    : String;
begin
  MousePos := GetMousePosition;

  // Decompter le timer du message de confirmation de sauvegarde
  if SavedMsgTimer > 0 then
    SavedMsgTimer := SavedMsgTimer - GetFrameTime;

  // -----------------------------------------------------------
  //  Mode chargement de fichiers : tout est deleguee a UFileIO
  // -----------------------------------------------------------
  if AppState = asFileSelect then
  begin
    HandleFileBrowserInput;
    Exit;
  end;

  // -----------------------------------------------------------
  //  Zoom a la molette (disponible dans tous les modes)
  //  Un cran positif = zoom avant, negatif = zoom arriere.
  // -----------------------------------------------------------
  WheelMove := GetMouseWheelMove;
  if WheelMove > 0 then
    HandleZoomAroundCursor(MousePos, 1.0 + ZOOM_STEP)
  else if WheelMove < 0 then
    HandleZoomAroundCursor(MousePos, 1.0 - ZOOM_STEP);

  // -----------------------------------------------------------
  //  Pan au clic droit maintenu
  //  On accumule le delta souris dans ViewOffset.
  // -----------------------------------------------------------
  if IsMouseButtonPressed(MOUSE_BUTTON_RIGHT) then
  begin
    IsPanning  := True;
    PanLastPos := MousePos;
  end;

  if IsMouseButtonReleased(MOUSE_BUTTON_RIGHT) then
    IsPanning := False;

  if IsPanning then
  begin
    ViewOffset.x := ViewOffset.x + (MousePos.x - PanLastPos.x);
    ViewOffset.y := ViewOffset.y + (MousePos.y - PanLastPos.y);
    PanLastPos   := MousePos;
  end;

  // -----------------------------------------------------------
  //  Mode edition
  // -----------------------------------------------------------
  if AppState = asEditing then
  begin
    // Shift accelere le deplacement x10
    MoveStep := MOVE_STEP;
    if IsKeyDown(KEY_LEFT_SHIFT) then
      MoveStep := MOVE_STEP * 10;

    // Selectionner une carte par clic gauche
    if IsMouseButtonPressed(MOUSE_BUTTON_LEFT) then
    begin
      if MapAtScreenPos(MousePos, ClickedRole) then
      begin
        SelectedMap  := ClickedRole;
        HasSelection := True;
      end
      else
        HasSelection := False;
    end;

    // Deplacer la carte selectionnee au pixel pres
    if HasSelection and Maps[SelectedMap].Loaded then
    begin
      if IsKeyPressed(KEY_LEFT)  then
        Maps[SelectedMap].Position.x := Maps[SelectedMap].Position.x - MoveStep;
      if IsKeyPressed(KEY_RIGHT) then
        Maps[SelectedMap].Position.x := Maps[SelectedMap].Position.x + MoveStep;
      if IsKeyPressed(KEY_UP)    then
        Maps[SelectedMap].Position.y := Maps[SelectedMap].Position.y - MoveStep;
      if IsKeyPressed(KEY_DOWN)  then
        Maps[SelectedMap].Position.y := Maps[SelectedMap].Position.y + MoveStep;
    end;

    // Tab : cycler la selection parmi les cartes chargees
    if IsKeyPressed(KEY_TAB) then
    begin
      if not HasSelection then
      begin
        SelectedMap  := mrLeft;
        HasSelection := True;
      end
      else
        case SelectedMap of
          mrLeft   : SelectedMap := mrCenter;
          mrCenter : SelectedMap := mrRight;
          mrRight  : SelectedMap := mrLeft;
        end;
      // Si la carte ciblee n est pas chargee, chercher la suivante
      if not Maps[SelectedMap].Loaded then
        HasSelection := False;
    end;

    // PageUp / PageDown : ajuster l alpha de la carte centrale
    // Increment de 5% par pression
    if IsKeyPressed(KEY_PAGE_UP) then
    begin
      Maps[mrCenter].Alpha := Maps[mrCenter].Alpha + 0.05;
      if Maps[mrCenter].Alpha > 1.0 then
        Maps[mrCenter].Alpha := 1.0;
    end;
    if IsKeyPressed(KEY_PAGE_DOWN) then
    begin
      Maps[mrCenter].Alpha := Maps[mrCenter].Alpha - 0.05;
      if Maps[mrCenter].Alpha < 0.0 then
        Maps[mrCenter].Alpha := 0.0;
    end;

    // + / - (clavier principal et pave numerique) :
    // ajuster la tolerance a la derive de couleur par pas de 5%.
    // Apres chaque modification on force le recalcul de la heatmap
    // pour que l effet soit immediatement visible.
    if IsKeyPressed(KEY_EQUAL) or IsKeyPressed(KEY_KP_ADD) then
    begin
      DriftTolerance := DriftTolerance + 0.05;
      if DriftTolerance > 1.0 then DriftTolerance := 1.0;
      ForceDiffRecalc;
    end;
    if IsKeyPressed(KEY_MINUS) or IsKeyPressed(KEY_KP_SUBTRACT) then
    begin
      DriftTolerance := DriftTolerance - 0.05;
      if DriftTolerance < 0.0 then DriftTolerance := 0.0;
      ForceDiffRecalc;
    end;

    // H : basculer l affichage de la heatmap
    if IsKeyPressed(KEY_H) then
      ShowHeatmap := not ShowHeatmap;

    // F5 : forcer le recalcul de la heatmap (utile apres un chargement)
    if IsKeyPressed(KEY_F5) then
      ForceDiffRecalc;

    // E : entrer en mode selection export (4 clics)
    if IsKeyPressed(KEY_E) then
    begin
      AppState    := asExportSelect;
      ExportStep  := 0;
      BandP1Set   := False;
      BandP2Set   := False;
      ExportP1Set := False;
      ExportP2Set := False;
    end;

    // F1 : revenir au navigateur de fichiers
    if IsKeyPressed(KEY_F1) then
    begin
      AppState := asFileSelect;
      // Rouvrir le navigateur dans le dossier de la carte centrale
      if Maps[mrCenter].Loaded then
        InitFileBrowser(ExtractFilePath(Maps[mrCenter].FilePath))
      else
        InitFileBrowser('');
    end;
  end

  // -----------------------------------------------------------
  //  Mode selection export : 4 clics sequentiels
  //  Zoom, pan et molette restent actifs a tout moment.
  //
  //  Etape 0 → clic → BandP1  (coin haut-gauche bande)
  //  Etape 1 → clic → BandP2  (coin bas-droit  bande)
  //  Etape 2 → clic → ExportP1 (coin haut-gauche export total)
  //  Etape 3 → clic → ExportP2 (coin bas-droit  export total)
  //  Etape 4 → Entree = sauvegarde, Echap = recommencer
  // -----------------------------------------------------------
  else if AppState = asExportSelect then
  begin
    // Mise a jour continue du curseur monde pour le rubber-band
    ExportMousePos := ScreenToWorld(MousePos);

    // Clic gauche : poser le prochain point selon l etape courante
    if IsMouseButtonPressed(MOUSE_BUTTON_LEFT) then
    begin
      case ExportStep of
        0: begin
             BandP1    := ScreenToWorld(MousePos);
             BandP1Set := True;
             ExportStep := 1;
           end;
        1: begin
             BandP2    := ScreenToWorld(MousePos);
             BandP2Set := True;
             ExportStep := 2;
           end;
        2: begin
             ExportP1    := ScreenToWorld(MousePos);
             ExportP1Set := True;
             ExportStep  := 3;
           end;
        3: begin
             ExportP2    := ScreenToWorld(MousePos);
             ExportP2Set := True;
             ExportStep  := 4;
             // Passer en mode confirmation
             AppState := asExportConfirm;
           end;
      end;
    end;

    // Echap : annuler et recommencer depuis le debut
    if IsKeyPressed(KEY_ESCAPE) then
    begin
      AppState    := asEditing;
      ExportStep  := 0;
      BandP1Set   := False;
      BandP2Set   := False;
      ExportP1Set := False;
      ExportP2Set := False;
    end;
  end

  // -----------------------------------------------------------
  //  Mode confirmation : les 4 points sont poses.
  //  Zoom et pan restes actifs pour verifier visuellement.
  //  Entree = lancer la sauvegarde
  //  Echap  = recommencer depuis le debut
  // -----------------------------------------------------------
  else if AppState = asExportConfirm then
  begin
    // Entree : sauvegarder les 2 PNG
    if IsKeyPressed(KEY_ENTER) or IsKeyPressed(KEY_KP_ENTER) then
    begin
      AppState := asMerging;
      SavePath := AutoSavePath;
      SaveMergedImage(SavePath);

      SavedMessage  := 'Sauvegarde : ' + ExtractFileName(SavePath) +
                       '  +  ' + ExtractFileName(ChangeFileExt(SavePath, '')) +
                       '_band.png';
      SavedMsgTimer := 6.0;

      AppState    := asEditing;
      ExportStep  := 0;
      BandP1Set   := False;
      BandP2Set   := False;
      ExportP1Set := False;
      ExportP2Set := False;
    end;

    // Echap : annuler et recommencer
    if IsKeyPressed(KEY_ESCAPE) then
    begin
      AppState    := asExportSelect;
      ExportStep  := 0;
      BandP1Set   := False;
      BandP2Set   := False;
      ExportP1Set := False;
      ExportP2Set := False;
    end;
  end;
end;

// ============================================================
//  DrawMapCard
//  Dessine une carte avec sa position monde, son zoom et son
//  alpha. DrawTexturePro permet de specifier source et dest
//  independamment, ce qui evite de modifier le ViewZoom de
//  raylib et reste coherent avec notre propre systeme de cam.
// ============================================================
procedure DrawMapCard(ARole: TMapRole);
var
  SrcRect  : TRectangle;
  DstRect  : TRectangle;
  Origin   : TVector2;
  Tint     : TColor;
  SPos     : TVector2;
begin
  if not Maps[ARole].Loaded then Exit;

  // Coin haut-gauche de la carte en coordonnees ecran
  SPos := WorldToScreen(Maps[ARole].Position);

  // Rectangle source = image entiere en pixels natifs
  SrcRect := MakeRect(0, 0, Maps[ARole].Width, Maps[ARole].Height);

  // Rectangle destination = position et taille a l ecran
  DstRect := MakeRect(SPos.x, SPos.y,
                      Maps[ARole].Width  * ViewZoom,
                      Maps[ARole].Height * ViewZoom);

  // Tint blanc avec alpha : canal A encode la transparence
  Tint := MakeColor(255, 255, 255, Round(Maps[ARole].Alpha * 255));

  Origin.x := 0;
  Origin.y := 0;

  DrawTexturePro(Maps[ARole].Texture, SrcRect, DstRect, Origin, 0.0, Tint);
end;

// ============================================================
//  DrawHeatmapOverlay
//  Dessine une texture heatmap etirée sur le rectangle monde
//  de chevauchement, converti en coordonnees ecran.
//  L etirement compense le sous-echantillonnage de SAMPLE_STEP.
// ============================================================
procedure DrawHeatmapOverlay(const HTex: TTexture2D;
                             const HRect: TRectangle);
var
  SrcRect : TRectangle;
  DstRect : TRectangle;
  ScrRect : TRectangle;
  Origin  : TVector2;
begin
  if HTex.id = 0 then Exit;

  // Source = la texture entiere (sous-echantillonnee)
  SrcRect := MakeRect(0, 0, HTex.width, HTex.height);

  // Destination = le rectangle overlap converti en ecran
  ScrRect := WorldRectToScreen(HRect);
  DstRect := ScrRect;

  Origin.x := 0;
  Origin.y := 0;

  // Dessiner sans teinture (WHITE = couleurs d origine)
  DrawTexturePro(HTex, SrcRect, DstRect, Origin, 0.0, WHITE);
end;

// ============================================================
//  DrawSelectionBorder
//  Cadre colore (jaune/or) autour de la carte selectionnee.
//  Un liser de 3px est ajoute en dehors de l image.
// ============================================================
procedure DrawSelectionBorder;
var
  SPos : TVector2;
  SR   : TRectangle;
begin
  if not HasSelection then Exit;
  if not Maps[SelectedMap].Loaded then Exit;

  SPos   := WorldToScreen(Maps[SelectedMap].Position);

  // On agrandit le cadre de 3px de chaque cote pour qu il
  // depasse legerement de l image et reste visible
  SR := MakeRect(SPos.x - 3,
                 SPos.y - 3,
                 Maps[SelectedMap].Width  * ViewZoom + 6,
                 Maps[SelectedMap].Height * ViewZoom + 6);

  DrawRectangleLinesEx(SR, 3, COLOR_SELECTED);
end;

// ============================================================
//  DrawRubberBand
//  Dessine un rectangle rubber-band entre deux points monde.
//  Si P2Set est False, le second coin suit la souris (ExportMousePos).
//  FillCol  = couleur de remplissage (semi-transparente)
//  LineCol  = couleur de bordure
//  Label    = texte affiche au-dessus du rectangle
// ============================================================
procedure DrawRubberBand(const P1: TVector2; P1Set: Boolean;
                         const P2: TVector2; P2Set: Boolean;
                         FillCol, LineCol: TColor;
                         const ALabel: String);
var
  SP1, SP2 : TVector2;
  WP2      : TVector2;
  SR       : TRectangle;
  DimStr   : String;
begin
  if not P1Set then Exit;

  SP1 := WorldToScreen(P1);

  if P2Set then
    SP2 := WorldToScreen(P2)
  else
    SP2 := WorldToScreen(ExportMousePos);

  SR := MakeRect(Min(SP1.x, SP2.x),
                 Min(SP1.y, SP2.y),
                 Abs(SP2.x - SP1.x),
                 Abs(SP2.y - SP1.y));

  // Remplissage semi-transparent
  DrawRectangle(Round(SR.x), Round(SR.y),
                Round(SR.width), Round(SR.height), FillCol);

  // Bordure
  DrawRectangleLinesEx(SR, 2, LineCol);

  // Marqueur coin P1
  DrawCircle(Round(SP1.x), Round(SP1.y), 5, LineCol);

  // Dimensions
  if P2Set then WP2 := P2 else WP2 := ExportMousePos;
  DimStr := ALabel + '  ' +
            Format('%d x %d px', [Round(Abs(WP2.x - P1.x)),
                                   Round(Abs(WP2.y - P1.y))]);
  DrawText(PChar(DimStr),
           Round(SR.x) + 6,
           Round(SR.y) - 22, 13, LineCol);
end;

// ============================================================
//  DrawExportOverlay
//  Affiche les 2 rectangles (bande bleue + export jaune) et
//  le bandeau d etape en haut de l ecran.
//  Appele depuis DrawScene quand AppState in [asExportSelect,
//  asExportConfirm].
// ============================================================
procedure DrawExportOverlay;
const
  // Couleurs bande centrale (bleu)
  BAND_FILL : TColor = (r:40;  g:100; b:220; a:40);
  BAND_LINE : TColor = (r:80;  g:160; b:255; a:220);
  // Couleurs export total (jaune)
  EXP_FILL  : TColor = (r:255; g:240; b:0;   a:22);
  EXP_LINE  : TColor = (r:255; g:220; b:0;   a:200);
var
  BannerText : String;
  BannerCol  : TColor;
  BW         : Integer;   // largeur du bandeau
begin
  // --- Dessiner la bande de priorite (bleue) ---
  DrawRubberBand(BandP1, BandP1Set,
                 BandP2, BandP2Set,
                 BAND_FILL, BAND_LINE, 'BANDE');

  // --- Dessiner le rectangle d export total (jaune) ---
  // Seulement visible a partir de l etape 2
  if ExportStep >= 2 then
    DrawRubberBand(ExportP1, ExportP1Set,
                   ExportP2, ExportP2Set,
                   EXP_FILL, EXP_LINE, 'EXPORT');

  // --- Bandeau d etape en haut de l ecran ---
  case ExportStep of
    0: begin
         BannerText := 'Clic 1/4 — Coin HAUT-GAUCHE de la BANDE DE PRIORITE (zone de pliure)';
         BannerCol  := BAND_LINE;
       end;
    1: begin
         BannerText := 'Clic 2/4 — Coin BAS-DROIT de la BANDE DE PRIORITE';
         BannerCol  := BAND_LINE;
       end;
    2: begin
         BannerText := 'Clic 3/4 — Coin HAUT-GAUCHE du RECTANGLE D''EXPORT TOTAL';
         BannerCol  := EXP_LINE;
       end;
    3: begin
         BannerText := 'Clic 4/4 — Coin BAS-DROIT du RECTANGLE D''EXPORT TOTAL';
         BannerCol  := EXP_LINE;
       end;
    4: begin
         BannerText := 'Pret — [Entree] Sauvegarder 2 PNG   [Echap] Recommencer';
         BannerCol  := MakeColor(60, 220, 60, 255);
       end;
  end;

  BW := MeasureText(PChar(BannerText), 15) + 40;
  DrawRectangle(ScreenWidth div 2 - BW div 2, 8, BW, 34,
                MakeColor(20, 20, 40, 220));
  DrawRectangleLines(ScreenWidth div 2 - BW div 2, 8, BW, 34, BannerCol);
  DrawText(PChar(BannerText),
           ScreenWidth div 2 - BW div 2 + 20, 16, 15, BannerCol);
end;

// ============================================================
//  DrawScene  (appelee dans BeginDrawing / EndDrawing)
//  Ordre de rendu :
//    1. Carte gauche   (opaque, dessous)
//    2. Carte droite   (opaque, dessous)
//    3. Carte centrale (semi-transparente, dessus)
//    4. Heatmap LC     (si ShowHeatmap)
//    5. Heatmap RC     (si ShowHeatmap)
//    6. Cadre de selection
//    7. Rectangle d export (si asExportSelect)
// ============================================================
procedure DrawScene;
begin
  // Le navigateur a son propre rendu complet
  if AppState = asFileSelect then
  begin
    DrawFileBrowser;
    Exit;
  end;

  // --- Cartes de fond : gauche et droite ---
  DrawMapCard(mrLeft);
  DrawMapCard(mrRight);

  // --- Carte centrale par-dessus ---
  DrawMapCard(mrCenter);

  // --- Heatmaps de bordure (4 cotes de la carte centrale) ---
  // Chaque bande est une fine texture etiree sur STRIP_W pixels monde.
  // Visible uniquement si ShowHeatmap est actif (touche H).
  if ShowHeatmap then
  begin
    if BorderReady[bsLeft]   then DrawHeatmapOverlay(BorderTex[bsLeft],   BorderRect[bsLeft]);
    if BorderReady[bsRight]  then DrawHeatmapOverlay(BorderTex[bsRight],  BorderRect[bsRight]);
    if BorderReady[bsTop]    then DrawHeatmapOverlay(BorderTex[bsTop],    BorderRect[bsTop]);
    if BorderReady[bsBottom] then DrawHeatmapOverlay(BorderTex[bsBottom], BorderRect[bsBottom]);
  end;

  // --- Cadre autour de la carte selectionnee ---
  DrawSelectionBorder;

  // --- Overlay export 4 points (bande bleue + export jaune + bandeau etape) ---
  if AppState in [asExportSelect, asExportConfirm] then
    DrawExportOverlay;
end;

// ============================================================
//  DrawUI  (appelee dans BeginDrawing / EndDrawing)
//  Barre d information en bas de l ecran.
// ============================================================
procedure DrawUI;
var
  BarY      : Integer;
  ScorePct  : Integer;
  ScoreCol  : TColor;
  ModeStr   : String;
  SelStr    : String;
  InfoStr   : String;
  RoleLabel : array[TMapRole] of String;
begin
  if AppState = asFileSelect then Exit;
  if AppState = asMerging   then Exit;

  RoleLabel[mrLeft]   := 'GAUCHE';
  RoleLabel[mrCenter] := 'CENTRALE';
  RoleLabel[mrRight]  := 'DROITE';

  BarY := ScreenHeight - UI_BAR_H;

  // --- Fond de la barre ---
  DrawRectangle(0, BarY, ScreenWidth, UI_BAR_H,
                MakeColor(15, 15, 25, 235));
  DrawLine(0, BarY, ScreenWidth, BarY, MakeColor(70, 70, 110, 255));

  // ---  Mode courant (col gauche) ---
  case AppState of
    asEditing       : ModeStr := 'MODE : EDITION';
    asExportSelect  : ModeStr := 'MODE : EXPORT (' + IntToStr(ExportStep) + '/4)';
    asExportConfirm : ModeStr := 'MODE : EXPORT — CONFIRMATION';
    asMerging       : ModeStr := 'MODE : FUSION...';
    else              ModeStr := '';
  end;
  DrawText(PChar(ModeStr), 12, BarY + 7, 16, WHITE);

  // --- Carte selectionnee + alpha ---
  if HasSelection and Maps[SelectedMap].Loaded then
  begin
    SelStr := 'Selection : ' + RoleLabel[SelectedMap] +
              '  (' + ExtractFileName(Maps[SelectedMap].FilePath) + ')';
    DrawText(PChar(SelStr), 12, BarY + 30, 13, COLOR_SELECTED);

    DrawText(PChar('Alpha centrale : ' +
                   IntToStr(Round(Maps[mrCenter].Alpha * 100)) +
                   '%   [PgUp / PgDn]'),
             12, BarY + 50, 12, LIGHTGRAY);
  end
  else
    DrawText('Clic gauche : selectionner une carte    [Tab] : cycler',
             12, BarY + 30, 13, LIGHTGRAY);

  // --- Raccourcis (ligne du bas) ---
  InfoStr := '[Fleches] deplacer 1px    [Shift+Fleches] 10px    ' +
             '[H] heatmap    [+/-] derive    [E] export    [F5] recalculer    [F1] charger';
  DrawText(PChar(InfoStr), 12, BarY + 70, 11, MakeColor(110, 110, 140, 255));

  // --- Score de correspondance (col droite) ---
  ScorePct := Round(DiffScore * 100);

  // Couleur : vert >= 90%, orange >= 60%, rouge < 60%
  if ScorePct >= 90 then
    ScoreCol := MakeColor(30, 220, 60, 255)
  else if ScorePct >= 60 then
    ScoreCol := MakeColor(220, 190, 30, 255)
  else
    ScoreCol := MakeColor(220, 50, 30, 255);

  DrawText('Correspondance :', ScreenWidth - 330, BarY + 7, 14, LIGHTGRAY);
  DrawText(PChar(IntToStr(ScorePct) + '%'),
           ScreenWidth - 110, BarY + 4, 30, ScoreCol);

  // Barre de progression du score
  DrawRectangle(ScreenWidth - 330, BarY + 32, 290, 10,
                MakeColor(35, 35, 35, 255));
  if ScorePct > 0 then
    DrawRectangle(ScreenWidth - 330, BarY + 32,
                  Round(290 * DiffScore), 10, ScoreCol);
  DrawRectangleLines(ScreenWidth - 330, BarY + 32, 290, 10,
                     MakeColor(70, 70, 90, 255));

  // Zoom courant
  DrawText(PChar('Zoom : ' + FormatFloat('0.00', ViewZoom) + 'x'),
           ScreenWidth - 330, BarY + 50, 12, LIGHTGRAY);

  // Tolerance a la derive (reglable avec + / -)
  DrawText(PChar('Derive : ' + IntToStr(Round(DriftTolerance * 100)) + '%   [+/-]'),
           ScreenWidth - 330, BarY + 64, 12, LIGHTGRAY);

  // Etat heatmap
  if ShowHeatmap then
    DrawText('[H] Heatmap ON',  ScreenWidth - 330, BarY + 78, 11,
             MakeColor(60, 200, 60, 255))
  else
    DrawText('[H] Heatmap OFF', ScreenWidth - 330, BarY + 78, 11,
             MakeColor(180, 70, 70, 255));

  // Le bandeau d etape export est desormais gere par DrawExportOverlay
  // dans DrawScene — rien a afficher ici.

  // --- Message de confirmation de sauvegarde ---
  if SavedMsgTimer > 0 then
  begin
    DrawRectangle(ScreenWidth div 2 - 270, BarY - 48, 540, 38,
                  MakeColor(20, 110, 20, 220));
    DrawRectangleLines(ScreenWidth div 2 - 270, BarY - 48, 540, 38,
                       MakeColor(80, 220, 80, 255));
    DrawText(PChar(SavedMessage),
             ScreenWidth div 2 - 250, BarY - 37, 14, WHITE);
  end;
end;

// ============================================================
//  initialization : valeurs par defaut
// ============================================================
initialization
  IsPanning      := False;
  ShowHeatmap    := True;      // heatmap visible au demarrage
  SavedMsgTimer  := 0.0;
  SavedMessage   := '';
  ExportMousePos.x := 0.0;
  ExportMousePos.y := 0.0;

end.
