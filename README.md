# HudExpBars

Mod UE4SS pour **Echoes of Aincrad** qui ajoute au HUD une jauge d'XP et une jauge de maîtrise d'arme.

Les deux jauges se placent en haut à gauche, à droite du panneau du premier équipier. Elles reprennent les textures et les matériaux des jauges du jeu, et s'affichent et se masquent avec elles. Aucun fichier du jeu n'est remplacé.

- **Or :** progression de l'XP dans le niveau actuel
- **Lavande :** progression de la maîtrise de l'arme équipée

## Installation

Il faut que [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) soit déjà installé.

Copie ce dossier dans `EchoesofAincrad\Binaries\Win64\ue4ss\Mods\`, sous le nom `HudExpBars`. Le fichier `enabled.txt` active le mod.

## Réglages

Tout se règle dans `Scripts/config.lua`. Relance le jeu après chaque modification.

| Réglage | Rôle |
|---|---|
| `OFFSET_X`, `OFFSET_Y` | Position dans le HUD |
| `GAUGE_WIDTH` | Longueur des jauges |
| `BAR_THICKNESS` | Épaisseur des barres |
| `EXP_COLOR`, `WEAPON_COLOR` | Couleurs des barres |

## Outils de diagnostic

Les résultats sont écrits dans `UE4SS.log`, sauf ceux de `Ctrl+F8`.

- `Ctrl+F9` : état du HUD et des jauges.
- `Ctrl+F8` : recherche des classes et des données du jeu, écrite dans `discovery.txt`. Le jeu peut se figer quelques secondes.
- `WATCH_HUD = true` dans la configuration : note les éléments du HUD qui apparaissent ou disparaissent.
- `DEBUG_LOGS = true` dans la configuration : ajoute des détails au log.
