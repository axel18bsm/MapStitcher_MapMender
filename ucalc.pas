unit UCalc;

{$mode objfpc}{$H+}

// ============================================================
//  UCalc - Calculs et superposition
//
//  Contenu :
//    - Transformations de coordonnees monde <-> ecran
//    - Detection des zones de chevauchement
//    - Generation des 4 heatmaps de BORDURE de la carte centrale
//      (gauche, droite, haut, bas) : UNE seule ligne de pixels
//      par cote, etiree pour etre visible a l ecran.
//    - UpdateDiffScore : score global de correspondance (0..1)
//
//  Principe du heatmap en mode bordure :
//    Pour chaque cote de la carte centrale, on echantillonne
//    la colonne (ou ligne) de pixels la plus externe.
//    On compare chaque pixel du bord de la centrale avec le pixel
//    de la carte adjacente (gauche ou droite) situe aux memes
//    coordonnees monde.
//    Resultat : 4 fines bandes colorees formant un cadre autour
//    de la carte centrale, lisible sans masquer le contenu.
//
//  Convention :
//    "monde"  = coordonnees en pixels image, independantes du zoom
//    "ecran"  = pixels de la fenetre raylib
//    screen = world * ViewZoom + ViewOffset
//    world  = (screen - ViewOffset) / ViewZoom
// ============================================================

interface

uses
  raylib, UGlobals, Math;

// -------------------------------------------------------
//  Variables exposees pour le rendu (utilisees par UEvents)
//  4 bandes : bord gauche, droit, haut, bas de la centrale
// -------------------------------------------------------
type
  TBorderSide = (bsLeft, bsRight, bsTop, bsBottom);

var
  // Une texture + un rectangle monde par cote de la centrale
  BorderTex   : array[TBorderSide] of TTexture2D;
  BorderRect  : array[TBorderSide] of TRectangle;
  BorderReady : array[TBorderSide] of Boolean;

// -------------------------------------------------------
//  Transformations de coordonnees
// -------------------------------------------------------
function WorldToScreen(const WPos: TVector2): TVector2;
function ScreenToWorld(const SPos: TVector2): TVector2;
function WorldRectToScreen(const WRect: TRectangle): TRectangle;

// -------------------------------------------------------
//  Chevauchement (conserve pour usage eventuel)
// -------------------------------------------------------
function GetOverlapRect(RoleA, RoleB: TMapRole;
                        out Overlap: TRectangle): Boolean;

// -------------------------------------------------------
//  Score de difference + heatmaps de bordure
// -------------------------------------------------------
procedure UpdateDiffScore;
procedure ForceDiffRecalc;

implementation

// ============================================================
//  Constantes internes
// ============================================================
const
  // Pas de sous-echantillonnage : 1 pixel heatmap = N pixels monde
  // Augmenter pour les tres grandes images (moins de calcul)
  SAMPLE_STEP = 4;

  // Seuil de difference acceptable par canal (0..255)
  DIFF_OK = 25;

  // Epaisseur en pixels monde de la bande affichee.
  // La texture elle-meme fait 1px, mais le rectangle de rendu
  // est elargi a STRIP_W pixels monde pour rester visible.
  STRIP_W = 6;

// ============================================================
//  Cache des positions pour le dirty flag
// ============================================================
var
  LastPos : array[TMapRole] of TVector2;

// ============================================================
//  WorldToScreen
// ============================================================
function WorldToScreen(const WPos: TVector2): TVector2;
begin
  Result.x := WPos.x * ViewZoom + ViewOffset.x;
  Result.y := WPos.y * ViewZoom + ViewOffset.y;
end;

// ============================================================
//  ScreenToWorld
// ============================================================
function ScreenToWorld(const SPos: TVector2): TVector2;
begin
  if ViewZoom = 0.0 then
  begin
    Result.x := 0;
    Result.y := 0;
    Exit;
  end;
  Result.x := (SPos.x - ViewOffset.x) / ViewZoom;
  Result.y := (SPos.y - ViewOffset.y) / ViewZoom;
end;

// ============================================================
//  WorldRectToScreen
// ============================================================
function WorldRectToScreen(const WRect: TRectangle): TRectangle;
begin
  Result.x      := WRect.x      * ViewZoom + ViewOffset.x;
  Result.y      := WRect.y      * ViewZoom + ViewOffset.y;
  Result.width  := WRect.width  * ViewZoom;
  Result.height := WRect.height * ViewZoom;
end;

// ============================================================
//  GetOverlapRect
//  Intersection geometrique de deux cartes en coords monde.
// ============================================================
function GetOverlapRect(RoleA, RoleB: TMapRole;
                        out Overlap: TRectangle): Boolean;
var
  AX1, AY1, AX2, AY2 : Single;
  BX1, BY1, BX2, BY2 : Single;
  OX1, OY1, OX2, OY2 : Single;
begin
  Result := False;
  Overlap.x := 0; Overlap.y := 0;
  Overlap.width := 0; Overlap.height := 0;

  if not Maps[RoleA].Loaded then Exit;
  if not Maps[RoleB].Loaded then Exit;

  AX1 := Maps[RoleA].Position.x;
  AY1 := Maps[RoleA].Position.y;
  AX2 := AX1 + Maps[RoleA].Width;
  AY2 := AY1 + Maps[RoleA].Height;

  BX1 := Maps[RoleB].Position.x;
  BY1 := Maps[RoleB].Position.y;
  BX2 := BX1 + Maps[RoleB].Width;
  BY2 := BY1 + Maps[RoleB].Height;

  OX1 := Max(AX1, BX1);
  OY1 := Max(AY1, BY1);
  OX2 := Min(AX2, BX2);
  OY2 := Min(AY2, BY2);

  if (OX2 <= OX1) or (OY2 <= OY1) then Exit;

  Overlap.x      := OX1;
  Overlap.y      := OY1;
  Overlap.width  := OX2 - OX1;
  Overlap.height := OY2 - OY1;
  Result := True;
end;

// ============================================================
//  ColorDiff
//  Difference moyenne sur R, G, B (alpha ignore).
//  0.0 = identiques, 255.0 = opposes.
// ============================================================
function ColorDiff(const CA, CB: TColor): Single;
begin
  Result := (Abs(Integer(CA.r) - Integer(CB.r)) +
             Abs(Integer(CA.g) - Integer(CB.g)) +
             Abs(Integer(CA.b) - Integer(CB.b))) / 3.0;
end;

// ============================================================
//  PixelColor
//  Retourne la couleur heatmap pour un ecart donne.
//  Vert  si diff <= DIFF_OK (bien aligne)
//  Rouge si diff >  DIFF_OK (mal aligne, intensite proportionnelle)
// ============================================================
function PixelColor(Diff: Single): TColor;
begin
  if Diff <= DIFF_OK then
  begin
    // Bien aligne : vert, leger
    Result.r := 10;
    Result.g := 210;
    Result.b := 50;
    Result.a := Round(100 + Diff * 2.0);   // 100..150
  end
  else
  begin
    // Mal aligne : rouge, de plus en plus opaque
    Result.r := 225;
    Result.g := Round(Max(0.0, 70.0 - Diff));
    Result.b := 10;
    Result.a := Round(Min(240.0, 130.0 + Diff));
  end;
end;

// ============================================================
//  FindUnderlyingColor
//  Pour un point monde (WX, WY), cherche un pixel dans les
//  cartes gauche ou droite (la centrale est ignoree car c est
//  elle que l on compare).
//  Retourne True et remplit Col si un pixel est trouve.
// ============================================================
function FindUnderlyingColor(WX, WY: Integer; out Col: TColor): Boolean;
var
  R    : TMapRole;
  LX, LY : Integer;
begin
  Result := False;
  for R := mrLeft to mrRight do
  begin
    if R = mrCenter then Continue;           // on ne compare pas la centrale avec elle-meme
    if not Maps[R].Loaded then Continue;

    LX := WX - Round(Maps[R].Position.x);
    LY := WY - Round(Maps[R].Position.y);

    if (LX >= 0) and (LX < Maps[R].Width) and
       (LY >= 0) and (LY < Maps[R].Height) then
    begin
      Col    := GetImageColor(Maps[R].Image, LX, LY);
      Result := True;
      Exit;
    end;
  end;
end;

// ============================================================
//  BuildBorderStrip
//  Construit la heatmap d un seul cote de la carte centrale.
//
//  Fonctionnement en deux passages :
//
//  PASSAGE 1 (si DriftTolerance > 0) :
//    Parcourt tous les echantillons du bord, accumule les ecarts
//    pour calculer la derive moyenne (MeanDrift).
//    MeanDrift represente le decalage systematique de couleur
//    entre les deux scans (luminosite, balance des blancs...).
//
//  PASSAGE 2 :
//    Construit l image heatmap en utilisant un ecart ajuste :
//      AdjustedDiff = max(0, Diff - MeanDrift * DriftTolerance)
//    A DriftTolerance=0 : comportement absolu (aucune compensation).
//    A DriftTolerance=1 : derive totalement soustraite, seules
//      les variations locales (vrai desalignement) sont visibles.
//
//  La procedure locale GetCoords centralise le calcul des
//  coordonnees pour eviter la duplication entre les 2 passages.
// ============================================================
procedure BuildBorderStrip(Side: TBorderSide;
                           out HeatTex  : TTexture2D;
                           out HRect    : TRectangle;
                           out GoodRatio: Single);

  // --------------------------------------------------------
  //  GetCoords : calcule les coordonnees monde (WX,WY) et
  //  locales dans la centrale (CenX, CenY) pour l echantillon
  //  d index I du cote Side.
  //  Valid = False si l index depasse les limites de la carte.
  // --------------------------------------------------------
  procedure GetCoords(CW, CH: Integer; CX, CY: Single; I: Integer;
                      out WX, WY, CenX, CenY: Integer;
                      out Valid: Boolean);
  begin
    Valid := True;
    case Side of
      bsLeft :
        begin
          WX   := Round(CX);
          WY   := Round(CY) + I * SAMPLE_STEP;
          CenX := 0;
          CenY := I * SAMPLE_STEP;
          if CenY >= CH then Valid := False;
        end;
      bsRight :
        begin
          WX   := Round(CX) + CW - 1;
          WY   := Round(CY) + I * SAMPLE_STEP;
          CenX := CW - 1;
          CenY := I * SAMPLE_STEP;
          if CenY >= CH then Valid := False;
        end;
      bsTop :
        begin
          WX   := Round(CX) + I * SAMPLE_STEP;
          WY   := Round(CY);
          CenX := I * SAMPLE_STEP;
          CenY := 0;
          if CenX >= CW then Valid := False;
        end;
      bsBottom :
        begin
          WX   := Round(CX) + I * SAMPLE_STEP;
          WY   := Round(CY) + CH - 1;
          CenX := I * SAMPLE_STEP;
          CenY := CH - 1;
          if CenX >= CW then Valid := False;
        end;
    end;
  end;

var
  CW, CH        : Integer;
  CX, CY        : Single;
  ImgW, ImgH    : Integer;
  NbSamples     : Integer;   // nombre d echantillons pour ce cote
  HeatImg       : TImage;
  I             : Integer;
  WX, WY        : Integer;
  CenX, CenY    : Integer;
  ColCenter     : TColor;
  ColUnder      : TColor;
  Diff          : Single;
  AdjustedDiff  : Single;    // diff apres compensation de la derive
  MeanDrift     : Single;    // derive moyenne calculee au passage 1
  DriftSum      : Single;    // somme des ecarts pour le calcul
  DriftCount    : Integer;   // nombre de pixels utilises
  GoodCount     : Integer;
  TotalCount    : Integer;
  Valid         : Boolean;
begin
  GoodRatio  := 0.0;
  HeatTex.id := 0;
  HRect.x := 0; HRect.y := 0; HRect.width := 0; HRect.height := 0;

  if not Maps[mrCenter].Loaded then Exit;

  CW := Maps[mrCenter].Width;
  CH := Maps[mrCenter].Height;
  CX := Maps[mrCenter].Position.x;
  CY := Maps[mrCenter].Position.y;

  // Nombre d echantillons et dimensions de la texture selon le cote
  case Side of
    bsLeft, bsRight :
      begin
        NbSamples := Max(1, CH div SAMPLE_STEP);
        ImgW := 1;
        ImgH := NbSamples;
      end;
    bsTop, bsBottom :
      begin
        NbSamples := Max(1, CW div SAMPLE_STEP);
        ImgW := NbSamples;
        ImgH := 1;
      end;
  else
    NbSamples := 1; ImgW := 1; ImgH := 1;
  end;

  // =====================================================
  //  PASSAGE 1 : calcul de la derive moyenne
  //  Skipe si tolerance a 0 (aucune compensation demandee)
  // =====================================================
  MeanDrift := 0.0;
  if DriftTolerance > 0.0 then
  begin
    DriftSum   := 0.0;
    DriftCount := 0;

    for I := 0 to NbSamples - 1 do
    begin
      GetCoords(CW, CH, CX, CY, I, WX, WY, CenX, CenY, Valid);
      if not Valid then Break;

      ColCenter := GetImageColor(Maps[mrCenter].Image, CenX, CenY);
      if FindUnderlyingColor(WX, WY, ColUnder) then
      begin
        DriftSum := DriftSum + ColorDiff(ColCenter, ColUnder);
        Inc(DriftCount);
      end;
    end;

    // Derive moyenne sur l ensemble du bord echantillonne
    if DriftCount > 0 then
      MeanDrift := DriftSum / DriftCount;
  end;

  // =====================================================
  //  PASSAGE 2 : construction de la heatmap
  //  AdjustedDiff = max(0, Diff - MeanDrift * Tolerance)
  // =====================================================
  HeatImg    := GenImageColor(ImgW, ImgH, BLANK);
  GoodCount  := 0;
  TotalCount := 0;

  for I := 0 to NbSamples - 1 do
  begin
    GetCoords(CW, CH, CX, CY, I, WX, WY, CenX, CenY, Valid);
    if not Valid then Break;

    ColCenter := GetImageColor(Maps[mrCenter].Image, CenX, CenY);
    if FindUnderlyingColor(WX, WY, ColUnder) then
    begin
      Diff         := ColorDiff(ColCenter, ColUnder);
      // Soustraire la part de la derive systematique
      AdjustedDiff := Max(0.0, Diff - MeanDrift * DriftTolerance);

      Inc(TotalCount);
      if AdjustedDiff <= DIFF_OK then Inc(GoodCount);

      // Ecrire le pixel heatmap selon l orientation du bord
      case Side of
        bsLeft, bsRight : ImageDrawPixel(@HeatImg, 0, I, PixelColor(AdjustedDiff));
        bsTop, bsBottom : ImageDrawPixel(@HeatImg, I, 0, PixelColor(AdjustedDiff));
      end;
    end;
  end;

  // Rectangle monde de la bande selon le cote
  case Side of
    bsLeft   : begin HRect.x := CX;             HRect.y := CY;             HRect.width := STRIP_W; HRect.height := CH;     end;
    bsRight  : begin HRect.x := CX + CW-STRIP_W; HRect.y := CY;            HRect.width := STRIP_W; HRect.height := CH;     end;
    bsTop    : begin HRect.x := CX;             HRect.y := CY;             HRect.width := CW;      HRect.height := STRIP_W; end;
    bsBottom : begin HRect.x := CX;             HRect.y := CY + CH-STRIP_W; HRect.width := CW;     HRect.height := STRIP_W; end;
  end;

  // Score partiel et upload GPU
  if TotalCount > 0 then
    GoodRatio := GoodCount / TotalCount
  else
    GoodRatio := 0.0;

  HeatTex := LoadTextureFromImage(HeatImg);
  UnloadImage(HeatImg);
end;

// ============================================================
//  CheckDirty
//  Retourne True si une carte a change de position.
// ============================================================
function CheckDirty: Boolean;
var
  R : TMapRole;
begin
  Result := False;
  for R := mrLeft to mrRight do
    if (Maps[R].Position.x <> LastPos[R].x) or
       (Maps[R].Position.y <> LastPos[R].y) then
    begin
      Result := True;
      Exit;
    end;
end;

procedure SavePositionCache;
var
  R : TMapRole;
begin
  for R := mrLeft to mrRight do
    LastPos[R] := Maps[R].Position;
end;

// ============================================================
//  DoRecalc
//  Reconstruit les 4 bandes heatmap et met a jour DiffScore.
// ============================================================
procedure DoRecalc;
var
  Side      : TBorderSide;
  Ratio     : Single;
  TotalScore: Single;
  Count     : Integer;
begin
  TotalScore := 0.0;
  Count      := 0;

  for Side := bsLeft to bsBottom do
  begin
    // Liberer l ancienne texture GPU si elle existait
    if BorderReady[Side] then
      UnloadTexture(BorderTex[Side]);

    BuildBorderStrip(Side, BorderTex[Side], BorderRect[Side], Ratio);

    BorderReady[Side] := (BorderTex[Side].id <> 0);

    // N accumuler le score que si des pixels ont ete compares
    if BorderReady[Side] and (Ratio > 0.0) then
    begin
      TotalScore := TotalScore + Ratio;
      Inc(Count);
    end;
  end;

  // Score global = moyenne des scores des 4 cotes
  if Count > 0 then
    DiffScore := TotalScore / Count
  else
    DiffScore := 0.0;
end;

// ============================================================
//  UpdateDiffScore  (appelee chaque frame)
// ============================================================
procedure UpdateDiffScore;
begin
  if not CheckDirty then Exit;
  SavePositionCache;
  DoRecalc;
end;

// ============================================================
//  ForceDiffRecalc  (recalcul immediat sans dirty check)
// ============================================================
procedure ForceDiffRecalc;
begin
  SavePositionCache;
  DoRecalc;
end;

// ============================================================
//  initialization
//  En Pascal objfpc, pas de var inline dans initialization.
//  On enumere chaque cote explicitement.
// ============================================================
initialization
  BorderReady[bsLeft]         := False;
  BorderTex[bsLeft].id        := 0;
  BorderRect[bsLeft].x        := 0; BorderRect[bsLeft].y       := 0;
  BorderRect[bsLeft].width    := 0; BorderRect[bsLeft].height  := 0;

  BorderReady[bsRight]        := False;
  BorderTex[bsRight].id       := 0;
  BorderRect[bsRight].x       := 0; BorderRect[bsRight].y      := 0;
  BorderRect[bsRight].width   := 0; BorderRect[bsRight].height := 0;

  BorderReady[bsTop]          := False;
  BorderTex[bsTop].id         := 0;
  BorderRect[bsTop].x         := 0; BorderRect[bsTop].y        := 0;
  BorderRect[bsTop].width     := 0; BorderRect[bsTop].height   := 0;

  BorderReady[bsBottom]       := False;
  BorderTex[bsBottom].id      := 0;
  BorderRect[bsBottom].x      := 0; BorderRect[bsBottom].y     := 0;
  BorderRect[bsBottom].width  := 0; BorderRect[bsBottom].height := 0;

  LastPos[mrLeft].x   := -99999.0;  LastPos[mrLeft].y   := -99999.0;
  LastPos[mrCenter].x := -99999.0;  LastPos[mrCenter].y := -99999.0;
  LastPos[mrRight].x  := -99999.0;  LastPos[mrRight].y  := -99999.0;

end.
