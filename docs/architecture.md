# Architecture

[Accueil](../README.md)

## Organisation

| Fichier | Responsabilite |
| --- | --- |
| `vmctl.ps1` | Parametres publics, validation et routage des actions. |
| `install.ps1` | Lanceur global et PATH utilisateur. |
| `scripts/Invoke-VmctlBootstrap.ps1` | Passage de Windows PowerShell 5.1 au moteur 7, avec arguments types et fichier temporaire protege. |
| `src/Vmctl.psm1` | Charge les implementations et expose quinze fonctions. |
| `src/Configuration.ps1` | Configuration, validation des cibles et choix du transport. |
| `src/Process.ps1` | Processus enfant, stdout/stderr, entree standard et timeout. |
| `src/Ssh.ps1` | SSH/SCP, commandes Windows/POSIX et diagnostics. |
| `src/PowerShellDirect.ps1` | Identification invite et delegation au worker PowerShell 5.1. |
| `src/HyperV.ps1` | Demarrage/arret, checkpoints et disques. |
| `src/Console.ps1` | Delegation des captures et entrees Hyper-V. |
| `src/Gpu.ps1`, `src/GpuSupport.psm1` | Worker GPU, quotas et validation des chemins. |
| `src/StreamingSupport.psm1` | Profils Moonlight, expiration des sessions et preuve de reception video. |
| `scripts/Start-StreamingSession.ps1` | Session elevee temporaire et reprise de la recette sans ressaisir les identifiants. |
| `scripts/Open-StreamingHost.ps1` | Ouverture/reconnexion du flux par UUID et verification de sa fenetre/journal. |
| `scripts/Start-InteractiveProcess.ps1` | Lancement de Moonlight avec le jeton de la session Windows normale. |
| `scripts/` | Workers Windows, installateurs et recettes. |
| `tests/` | Tests locaux et test explicite sur une vraie VM. |
| `docs/` | Guides par workflow. |

Les fichiers `src/*.ps1` sont charges par dot-sourcing dans le meme module et ne sont pas des commandes autonomes. Les workers gardent leur processus et leur version PowerShell propres.

Le lanceur global accepte Windows PowerShell 5.1 et appelle directement le CLI depuis PowerShell 7.2+. Depuis 5.1, il utilise le chemin absolu du moteur memorise a l'installation. Les arguments passent par CLIXML dans un dossier temporaire accessible uniquement a l'utilisateur et SYSTEM ; les identifiants sont chiffres par DPAPI. Le fichier est supprime en fin d'appel. Ce passage conserve les commutateurs explicites, Unicode et codes de sortie sans interpreter les arguments dans cmd.exe.

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
Les liaisons `streaming-bindings/<alias>.json` associent le GUID Hyper-V au UUID Apollo. Elles restent independantes du repertoire de rapports et permettent un nom Windows different du nom Hyper-V.

`work/` contient telechargements et fixtures ; `bin/` les lanceurs generes. `.gitignore` exclut aussi credentials, certificats, archives et executables. Verifier le contenu avant publication reste necessaire.

## Ajouter une fonctionnalite

Ajouter l'action et ses gardes dans `vmctl.ps1`, puis la logique dans le fichier `src/` correspondant ou un worker. Documenter prerequis, effets et limites dans le guide concerne. Tester les gardes avant mutation et les contrats de sortie ; utiliser un test reel uniquement si necessaire.

Apres modification des parametres publics, relancer `install.ps1` : le lanceur genere reprend leur declaration. [Tests](testing.md).

## Limites actuelles

Chaque appel Direct cree puis ferme sa session. `run` transfere un script unique sans arguments de script. Le routage reste dans un seul CLI ; le worker GPU et le client API Apollo sont plus longs que les autres fichiers et pourront etre subdivises si leur responsabilite s'elargit. Les recettes GPU/streaming sont specifiques a Windows/Hyper-V/NVIDIA ; le transport SSH est plus general.
