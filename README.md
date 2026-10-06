# vmctl

Un CLI PowerShell pour executer des commandes dans une VM, transferer des fichiers, gerer Hyper-V et preparer un bureau Moonlight/Apollo avec GPU-P.

**Windows dans Hyper-V local utilise PowerShell Direct** : aucun serveur SSH ou WinRM a installer dans la VM. Les autres cibles utilisent SSH avec verification de la cle hote. La console Hyper-V fournit captures et entrees clavier/souris.

## Installation et premier appel

Prerequis : PowerShell 7.2+ sur l'hote. Pour Direct : Hyper-V et Windows PowerShell 5.1 sur Windows, une VM Windows demarree et un compte avec un vrai mot de passe. Le PIN Windows Hello ne remplace pas ce mot de passe.

Executer `install.ps1` depuis PowerShell 7. Ensuite, la commande globale `vmctl` fonctionne aussi depuis Windows PowerShell 5.1 : le lanceur demarre automatiquement le moteur PowerShell 7 installe, sans alias ni configuration de profil.

```powershell
.\install.ps1
vmctl register -Vm ma-vm -Os windows -Hypervisor hyperv -UserName vmctl-admin
$cred = Get-Credential -UserName vmctl-admin
vmctl doctor -Vm ma-vm -Credential $cred
vmctl exec -Vm ma-vm -Credential $cred -Command 'hostname; whoami'
```

Ouvrir un nouveau terminal apres installation pour actualiser le PATH. Pour Hyper-V, utiliser un terminal administrateur sur l'hote ; les droits de l'hote et ceux du compte invite sont distincts. Direct est delegue a Windows PowerShell 5.1.

```powershell
vmctl run -Vm ma-vm -Credential $cred -File .\script.ps1
vmctl upload -Vm ma-vm -Credential $cred -Source .\package.zip -Destination C:/Temp/package.zip
vmctl help
```

Les cibles sont dans `%USERPROFILE%\.vmctl\targets.json`, hors du depot. `-Config PATH` ou `VMCTL_CONFIG` choisit un autre fichier. `targets.example.json` ne contient aucun secret. `register` refuse de remplacer une cible existante.

Les donnees utilisateur sont partagees entre applications et terminaux, hors de la virtualisation AppData des applications MSIX. `install.ps1` migre une ancienne configuration AppData visible depuis son contexte, ses identifiants chiffres et ses liaisons streaming ; les anciennes donnees sont conservees. Relancer l'installateur ne remplace pas une configuration deja migree.

## Moonlight, Apollo et GPU-P

Sur une VM Windows deja preparee avec un compte administrateur et un mot de passe, depuis le terminal hote administrateur :

```powershell
vmctl gpu-setup -Vm ma-vm -GpuName 'NVIDIA GeForce RTX 4090' -GpuPercent 25
vmctl streaming-install -Vm ma-vm -Open
vmctl streaming-status -Vm ma-vm -Diagnostics
# Connexions suivantes, sans mot de passe Windows ni UAC :
vmctl streaming-open -Vm ma-vm
vmctl streaming-open -Vm ma-vm -Mode fullscreen -Reconnect
vmctl shortcut install --name "VM - Fenetre" --mode windowed
vmctl shortcut install --name "VM - Plein ecran" --mode fullscreen
vmctl shortcut uninstall --name "VM - Fenetre"
```

La recette reutilise Moonlight, installe Apollo, prepare le rendu GPU-P NVIDIA, redemarre la VM si necessaire et effectue l'appairage automatiquement. `-Open` ouvre Virtual Display avec les preferences Moonlight conservees. La reception video est verifiee dans le journal client ; la fluidite et le son exigent un essai reel. Le service demarre avec Windows et la synchronisation des pilotes GPU-P est planifiee sur l'hote. Les budgets GPU-P ne garantissent pas un pourcentage identique de performances de jeu.

Windows doit deja etre initialise dans la VM. Cette recette ne cree pas la VM et n'installe pas Atlas automatiquement. [Installation, reglages et diagnostic streaming](docs/streaming.md).

## Documentation

- [Commandes, transports, configuration et console](docs/usage.md)
- [Moonlight/Apollo, GPU-P et ecrans noirs](docs/streaming.md)
- [Raccourcis du bureau et choix de VM](docs/shortcuts.md)
- [Audit du setup et nettoyage complet](docs/streaming-audit.md)
- [Disques, compaction et checkpoints](docs/storage.md)
- [Architecture du code et ajout d'une commande](docs/architecture.md)
- [Tests locaux et essais sur une vraie VM](docs/testing.md)

## Organisation et verification

`vmctl.ps1` est le point d'entree. `src/` contient les modules ; `scripts/` les workers et recettes ; `tests/` les verifications ; `docs/` les guides. `bin/` et `work/` sont generes localement et ignores par Git.

```powershell
.\tests\Test-Vmctl.ps1
.\tests\Test-DataPaths.ps1
.\tests\Test-PowerShellDirect.ps1
.\tests\Test-ConsoleGuards.ps1
.\tests\Test-GpuPlanning.ps1
.\tests\Test-StreamingSupport.ps1
.\tests\Test-Shortcuts.ps1
```

Ces tests n'utilisent aucune VM. Les essais reels sont explicites et documentes separement. Les configurations locales, identifiants, installateurs, captures et rapports ne doivent pas etre publies.
