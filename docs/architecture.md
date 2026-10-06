# Architecture

[Accueil](../README.md)

## Organisation

| Fichier | Responsabilite |
| --- | --- |
| `vmctl.ps1` | Parametres publics, validation et routage des actions. |
| `install.ps1` | Lanceur global et PATH utilisateur. |
| `src/Vmctl.psm1` | Charge les implementations et expose quinze fonctions. |
| `src/Configuration.ps1` | Configuration, validation des cibles et choix du transport. |
| `src/Process.ps1` | Processus enfant, stdout/stderr, entree standard et timeout. |
| `src/Ssh.ps1` | SSH/SCP, commandes Windows/POSIX et diagnostics. |
| `src/PowerShellDirect.ps1` | Identification invite et delegation au worker PowerShell 5.1. |
| `src/HyperV.ps1` | Demarrage/arret, checkpoints et disques. |
| `src/Console.ps1` | Delegation des captures et entrees Hyper-V. |
| `src/Gpu.ps1`, `src/GpuSupport.psm1` | Worker GPU, quotas et validation des chemins. |
| `scripts/` | Workers Windows, installateurs et recettes. |
| `tests/` | Tests locaux et test explicite sur une vraie VM. |
| `docs/` | Guides par workflow. |

Les fichiers `src/*.ps1` sont charges par dot-sourcing dans le meme module et ne sont pas des commandes autonomes. Les workers gardent leur processus et leur version PowerShell propres.

## Parcours d'une commande

1. Le CLI valide les options et charge la cible.
2. Pour `exec`, `run` et `upload`, il choisit Direct ou SSH.
3. Direct utilise Windows PowerShell 5.1 et une session temporaire dans l'invite. SSH utilise SSH/SCP.
4. Hyper-V, console et GPU utilisent des workers ou processus dedies.
5. Le resultat conserve le code de sortie et stdout/stderr.

Les recettes Apollo passent par le CLI public pour les operations dans la VM. Le diagnostic Apollo depuis l'hote utilise HTTPS, le compte Apollo sous DPAPI et le certificat deja appaire dans Moonlight. Il ne demande pas le mot de passe Windows invite.

## Droits et donnees locales

Les droits Hyper-V de l'hote et les droits administrateur de l'invite sont distincts. Une session Windows ouverte dans la VM ne fournit pas ses identifiants a Direct.

Les cibles et comptes Apollo sont dans `%LOCALAPPDATA%\vmctl`. Les caches de mots de passe Windows crees par la recette d'installation sont temporaires. Les donnees GPU et workers proteges sont dans ProgramData/Program Files. Ces fichiers restent hors du depot.

`work/` contient telechargements et fixtures ; `bin/` les lanceurs generes. `.gitignore` exclut aussi credentials, certificats, archives et executables. Verifier le contenu avant publication reste necessaire.

## Ajouter une fonctionnalite

Ajouter l'action et ses gardes dans `vmctl.ps1`, puis la logique dans le fichier `src/` correspondant ou un worker. Documenter prerequis, effets et limites dans le guide concerne. Tester les gardes avant mutation et les contrats de sortie ; utiliser un test reel uniquement si necessaire.

Apres modification des parametres publics, relancer `install.ps1` : le lanceur genere reprend leur declaration. [Tests](testing.md).

## Limites actuelles

Chaque appel Direct cree puis ferme sa session. `run` transfere un script unique sans arguments de script. Le routage reste dans un seul CLI ; le worker GPU et le client API Apollo sont plus longs que les autres fichiers et pourront etre subdivises si leur responsabilite s'elargit. Les recettes GPU/streaming sont specifiques a Windows/Hyper-V/NVIDIA ; le transport SSH est plus general.
