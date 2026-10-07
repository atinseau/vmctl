# Verification

[Accueil](../README.md) · [Architecture](architecture.md)

## Tests locaux sans VM

Depuis la racine, avec PowerShell 7.2+ sur Windows (generer les lanceurs avant les tests) :

```powershell
.\install.ps1
.\tests\Test-Vmctl.ps1
.\tests\Test-AdminBroker.ps1
.\tests\Test-DataPaths.ps1
.\tests\Test-PowerShellDirect.ps1
.\tests\Test-ConsoleGuards.ps1
.\tests\Test-GpuPlanning.ps1
.\tests\Test-StreamingSupport.ps1
```

| Script | Verification |
| --- | --- |
| `Test-Vmctl.ps1` | Commandes Windows/POSIX, Unicode, codes de sortie, erreurs, timeouts, arguments et options incompatibles avant mutation. |
| `Test-PowerShellDirect.ps1` | Transport, planification Direct et compatibilite DPAPI entre PowerShell 7 et 5.1. |
| `Test-DataPaths.ps1` | Migration sans remplacement, preservation de l'appairage, exclusion des caches expires et racine identique dans PowerShell 5.1 et 7. |
| `Test-ConsoleGuards.ps1` | Captures, entrees, usage unique des frames et conversion RGB565, sans console VM. |
| `Test-GpuPlanning.ps1` | Calcul UInt64 des budgets, empreintes et refus de chemins dangereux. |
| `Test-StreamingSupport.ps1` | Profils par UUID/adresse, conservation de QSettings, expiration avec dates JSON, refus de faux indicateurs de reception video, reprise bornee des lectures Apollo et erreurs sans codes ANSI. |

Les fixtures restent dans `work/`, ignore par Git. Certains essais de compilateur ou de shell POSIX sont ignores si ces outils sont indisponibles ; le resultat le signale. Un test local reussi ne confirme pas un streaming dans une VM.
Le test CLI appelle le lanceur global depuis PowerShell 7 et Windows PowerShell 5.1, avec Unicode, guillemets, commande de plus de 64 Ko, commutateur explicitement false et PSCredential. Il verifie aussi la conservation du code de sortie et de stderr.
Le test streaming utilise uniquement une cle HKCU temporaire sous `Software\vmctl-tests`, supprimee en fin de test. Il peut etre execute pendant un flux Moonlight ; il ne modifie pas les vrais profils.

## Test explicite sur une vraie VM

VM enregistree et demarree, avec les droits Hyper-V sur l'hote :

```powershell
$cred = Get-Credential -UserName vmctl-admin
.\tests\Test-RealVm.ps1 -Vm ma-vm -Credential $cred
```

Ce test cree des fichiers temporaires, verifie l'identite, un transfert SHA-256, un script Unicode et les erreurs/codes, puis nettoie ses fichiers. Il n'installe pas Atlas ou Apollo et ne teste pas les jeux.

Pour le CLI global et Moonlight, tester aussi depuis Windows Terminal normal. Un enfant d'une application MSIX peut heriter de sa vue privee d'AppData et du registre ; un test execute uniquement depuis cette application ne prouve pas que la session utilisateur voit la meme configuration ou le meme profil Moonlight.

Les scripts `scripts/Test-*Guest.ps1` s'executent dans l'invite avec `vmctl run`. Lire leurs prerequis avant de les lancer.

## Avant publication

Executer les tests locaux apres modification du routage ou des modules. Verifier `git diff --cached` et `git status --ignored` : seuls sources, exemples sans secrets, documentation et tests doivent etre suivis. Ne pas publier configurations locales, identifiants, rapports ou caches d'installation.
