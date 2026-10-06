# vmctl

Un CLI PowerShell pour executer des commandes dans une VM, transferer des fichiers, gerer Hyper-V et preparer un bureau Moonlight/Apollo avec GPU-P.

**Windows dans Hyper-V local utilise PowerShell Direct** : aucun serveur SSH ou WinRM a installer dans la VM. Les autres cibles utilisent SSH avec verification de la cle hote. La console Hyper-V fournit captures et entrees clavier/souris.

## Installation et premier appel

Prerequis : PowerShell 7.2+ sur l'hote. Pour Direct : Hyper-V et Windows PowerShell 5.1 sur Windows, une VM Windows demarree et un compte avec un vrai mot de passe. Le PIN Windows Hello ne remplace pas ce mot de passe.

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

Les cibles sont dans `%LOCALAPPDATA%\vmctl\targets.json`, hors du depot. `-Config PATH` ou `VMCTL_CONFIG` choisit un autre fichier. `targets.example.json` ne contient aucun secret. `register` refuse de remplacer une cible existante.

## Moonlight, Apollo et GPU-P

Sur une VM Windows deja preparee avec un compte administrateur et un mot de passe, depuis le terminal hote administrateur :

```powershell
vmctl gpu-setup -Vm ma-vm -GpuName 'NVIDIA GeForce RTX 4090' -GpuPercent 25
vmctl streaming-install -Vm ma-vm
vmctl streaming-status -Vm ma-vm -Diagnostics
```

La recette reutilise Moonlight, installe Apollo, configure NVENC lorsqu'un GPU NVIDIA sain est attribue et effectue l'appairage automatiquement. Le service demarre avec Windows. La synchronisation des pilotes GPU-P est planifiee sur l'hote. Verifier ensuite un vrai flux : l'installation ne valide pas sa fluidite. Les budgets GPU-P ne garantissent pas un pourcentage identique de performances de jeu.

Windows doit deja etre initialise dans la VM. Cette recette ne cree pas la VM et n'installe pas Atlas automatiquement. [Installation, reglages et diagnostic streaming](docs/streaming.md).

## Documentation

- [Commandes, transports, configuration et console](docs/usage.md)
- [Moonlight/Apollo, GPU-P et ecrans noirs](docs/streaming.md)
- [Audit du setup et nettoyage complet](docs/streaming-audit.md)
- [Disques, compaction et checkpoints](docs/storage.md)
- [Architecture du code et ajout d'une commande](docs/architecture.md)
- [Tests locaux et essais sur une vraie VM](docs/testing.md)

## Organisation et verification

`vmctl.ps1` est le point d'entree. `src/` contient les modules ; `scripts/` les workers et recettes ; `tests/` les verifications ; `docs/` les guides. `bin/` et `work/` sont generes localement et ignores par Git.

```powershell
.\tests\Test-Vmctl.ps1
.\tests\Test-PowerShellDirect.ps1
.\tests\Test-ConsoleGuards.ps1
.\tests\Test-GpuPlanning.ps1
.\tests\Test-StreamingSupport.ps1
```

Ces tests n'utilisent aucune VM. Les essais reels sont explicites et documentes separement. Les configurations locales, identifiants, installateurs, captures et rapports ne doivent pas etre publies.
