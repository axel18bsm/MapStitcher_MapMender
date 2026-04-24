program rassembleur;

{$mode objfpc}{$H+}

uses
  raylib,
  SysUtils,
  UGlobals,
  UFileIO,
  UEvents,
  UCalc;

// ------------------------------------------------------------
//  Initialisation de l application
// ------------------------------------------------------------
procedure InitApp;
var
  R : TMapRole;
begin
  ScreenWidth  := WINDOW_WIDTH;
  ScreenHeight := WINDOW_HEIGHT;

  InitWindow(ScreenWidth, ScreenHeight, WINDOW_TITLE);
  SetTargetFPS(TARGET_FPS);

  // Initialiser chaque carte a vide
  for R := mrLeft to mrRight do
  begin
    Maps[R].Loaded   := False;
    Maps[R].Role     := R;
    Maps[R].Alpha    := 1.0;
    Maps[R].Position.x := 0;
    Maps[R].Position.y := 0;
    Maps[R].FilePath := '';
    Maps[R].Width    := 0;
    Maps[R].Height   := 0;
  end;

  // La carte centrale demarre en semi-transparent
  Maps[mrCenter].Alpha := CENTER_ALPHA_DEFAULT;

  // Vue par defaut
  ViewZoom     := 1.0;
  ViewOffset.x := 0;
  ViewOffset.y := 0;

  // Etat initial : selection des fichiers
  AppState     := asFileSelect;
  HasSelection := False;
  ExportP1Set  := False;
  ExportP2Set  := False;
  DiffScore      := 0.0;
  LastSavedPath  := '';
  DriftTolerance := 0.0;   // 0% par defaut : comparaison stricte

  // Ouvrir le navigateur dans le dossier de l executable au demarrage.
  // ExtractFilePath(ParamStr(0)) donne le dossier du .exe sous Windows.
  InitFileBrowser(ExtractFilePath(ParamStr(0)));
end;

// ------------------------------------------------------------
//  Liberation des ressources
// ------------------------------------------------------------
procedure CleanupApp;
var
  R : TMapRole;
begin
  for R := mrLeft to mrRight do
    if Maps[R].Loaded then
    begin
      UnloadTexture(Maps[R].Texture);
      UnloadImage(Maps[R].Image);
    end;

  CloseWindow;
end;

// ------------------------------------------------------------
//  Programme principal
// ------------------------------------------------------------
begin
  InitApp;

  while not WindowShouldClose do
  begin
    // 1. Traitement de tous les evenements (clavier, souris, zoom, pan)
    HandleEvents;

    // 2. Recalcul du score de difference dans les zones de chevauchement
    if AppState = asEditing then
      UpdateDiffScore;

    // 3. Rendu
    BeginDrawing;
      ClearBackground(DARKGRAY);
      DrawScene;   // les 3 cartes + heatmap
      DrawUI;      // panneau de controle + infos
    EndDrawing;
  end;

  CleanupApp;
end.
