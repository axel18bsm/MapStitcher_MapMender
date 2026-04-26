unit UGlobals;

{$mode objfpc}{$H+}

interface

uses
  raylib;

// ============================================================
//  CONSTANTES
// ============================================================
const
  WINDOW_WIDTH         = 1280;
  WINDOW_HEIGHT        = 720;
  WINDOW_TITLE         = 'MapStitcher - Wargame';

  TARGET_FPS           = 60;

  // Alpha de la carte centrale en mode edition (0.0 = invisible, 1.0 = opaque)
  CENTER_ALPHA_DEFAULT : Single = 0.55;

  // Deplacement au pixel pres (touches directionnelles)
  MOVE_STEP            = 1;

  // Zoom
  ZOOM_MIN  : Single = 0.05;
  ZOOM_MAX  : Single = 8.0;
  ZOOM_STEP : Single = 0.1;

  // Seuil de difference acceptable pour le heatmap (0..255)
  DIFF_THRESHOLD = 20;

  // Couleurs UI
  COLOR_SELECTED : TColor = (r:255; g:200; b:0;   a:255);   // jaune  = carte selectionnee
  COLOR_GOOD     : TColor = (r:0;   g:220; b:60;  a:160);   // vert   = pixels identiques
  COLOR_BAD      : TColor = (r:220; g:30;  b:30;  a:160);   // rouge  = pixels differents
  COLOR_UI_BG    : TColor = (r:30;  g:30;  b:30;  a:220);   // fond panneau UI

// ============================================================
//  TYPES
// ============================================================
type

  // Role de chaque carte dans l assemblage
  TMapRole = (mrLeft, mrCenter, mrRight);

  // Etat global de l application
  TAppState = (
    asFileSelect,    // chargement / attribution des 3 cartes
    asEditing,       // edition : deplacement, zoom, pan
    asExportSelect,  // l utilisateur pose les 4 points d export
    asExportConfirm, // confirmation avant sauvegarde (Entree / Echap)
    asMerging        // calcul et sauvegarde du PNG final
  );

  // Sous-etape de saisie en mode asExportSelect (0 a 4)
  // 0 = rien pose
  // 1 = BandP1 pose, attente BandP2
  // 2 = bande complete, attente ExportP1
  // 3 = ExportP1 pose, attente ExportP2
  // 4 = tous les points poses, pret a confirmer
  TExportStep = 0..4;

  // Toutes les donnees d une carte
  TMapCard = record
    Texture  : TTexture2D;   // texture GPU chargee par raylib
    Image    : TImage;       // image CPU (pixels) pour les calculs
    Position : TVector2;     // offset (x,y) sur le canvas monde
    Alpha    : Single;       // 0.0 .. 1.0
    Role     : TMapRole;
    Loaded   : Boolean;
    FilePath : String;
    Width    : Integer;      // dimensions en pixels
    Height   : Integer;
  end;

// ============================================================
//  VARIABLES GLOBALES
// ============================================================
var

  // --- Les 3 cartes ---
  Maps         : array[TMapRole] of TMapCard;

  // --- Selection courante ---
  SelectedMap  : TMapRole;
  HasSelection : Boolean;

  // --- Vue (zoom + pan) ---
  ViewZoom     : Single;      // facteur de zoom courant
  ViewOffset   : TVector2;    // decalage de la camera en pixels monde

  // --- Etat de l application ---
  AppState     : TAppState;

  // --- Bande de priorite centrale (coordonnees monde) ---
  // Points 1 et 2 des 4 clics : zone ou la carte centrale est prioritaire
  BandP1       : TVector2;    // coin haut-gauche de la bande
  BandP2       : TVector2;    // coin bas-droit  de la bande
  BandP1Set    : Boolean;
  BandP2Set    : Boolean;

  // --- Rectangle d export total (coordonnees monde) ---
  // Points 3 et 4 des 4 clics : perimetre final du PNG sauvegarde
  ExportP1     : TVector2;    // coin haut-gauche
  ExportP2     : TVector2;    // coin bas-droit
  ExportP1Set  : Boolean;
  ExportP2Set  : Boolean;

  // --- Etape courante de saisie en mode asExportSelect (0..4) ---
  ExportStep   : TExportStep;

  // --- Qualite d alignement (0.0 = nul .. 1.0 = parfait) ---
  DiffScore    : Single;

  // --- Tolerance a la derive de couleur entre scans (0.0 .. 1.0) ---
  // 0.0 = comparaison absolue (pas de compensation)
  // 1.0 = derive moyenne totalement soustraite (seules les variations locales comptent)
  // Reglable par l utilisateur avec + / - par pas de 5 %
  DriftTolerance : Single;

  // --- Dimensions reelles de la fenetre ---
  ScreenWidth  : Integer;
  ScreenHeight : Integer;

  // --- Chemin du dernier fichier sauvegarde ---
  LastSavedPath : String;

implementation

end.
