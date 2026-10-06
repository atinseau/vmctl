[Accueil](../README.md) · [Architecture](architecture.md)

## Transport adapte a la cible

- **Windows dans Hyper-V local : PowerShell Direct** (`Invoke-Command`, `New-PSSession`, `Copy-Item -ToSession`). Aucun SSH, IP, pare-feu ou WinRM a preparer.
- **Linux, autres hyperviseurs, machines distantes : SSH/SFTP**. Serveur SSH et cle hote verifiee requis.
- `transport: "auto"` choisit Direct pour Windows + Hyper-V, SSH sinon. `psdirect` et `ssh` permettent un choix explicite. `-Transport` le remplace pour un appel.

## Hyper-V Windows local

Ouvrir une fois le terminal de l'hote en administrateur, ou utiliser un compte membre des administrateurs Hyper-V. Windows 10+/Server 2016+ sur l'hote et l'invite, VM demarree et profil utilisateur configure.

```powershell
vmctl register -Vm autre-vm -Os windows -Hypervisor hyperv
$cred = Get-Credential -UserName 'win-vm\vmctl-admin'
vmctl doctor -Vm win-vm -Credential $cred
vmctl exec -Vm win-vm -Credential $cred -Command 'hostname; whoami'
vmctl run -Vm win-vm -Credential $cred -File .\script.ps1
vmctl upload -Vm win-vm -Credential $cred -Source .\package.zip -Destination C:/Temp/package.zip
```

Direct exige un compte et un **mot de passe de la VM** ; un PIN Windows Hello ne suffit pas. Un compte administrateur dans l'invite est necessaire pour installer des logiciels. Sans `-Credential` ou `-CredentialFile`, vmctl demande les identifiants avec `Get-Credential`. La session Windows deja ouverte n'autorise pas implicitement l'hote.

Le CLI PS7 delegue les appels natifs a Windows PowerShell 5.1. La requete passe sur stdin ; le mot de passe est protege par DPAPI, jamais en clair dans les arguments ni dans `targets.json`. Aucun serveur ou agent n'est installe dans la VM. Chaque appel cree une session Direct et la ferme ensuite.

Les droits administrateur de la VM et de l'hote sont distincts. Reutiliser un seul terminal hote eleve pour toute une serie d'appels evite les demandes UAC repetees ; vmctl ne doit pas relancer ce terminal pour chaque commande. Une VM neuve exige uniquement un compte Windows avec mot de passe, `vmctl register`, puis `vmctl doctor`. Les appels Direct n'exigent aucune configuration reseau.

## SSH pour les autres cibles

```powershell
vmctl register -Vm debian -HostName debian-vm -Os linux -UserName admin
vmctl exec -Vm debian -Command 'uname -a'
```

Configurer SSH, la cle publique et le pare-feu dans l'invite ; comparer la cle hote via une source fiable et faire la premiere connexion manuellement. `BatchMode=yes` et verification de cle stricte ; aucune validation automatique. Windows SSH peut utiliser `scripts/Initialize-VmSsh.ps1` depuis une console invite administrateur. Ce script **ne sert pas aux VM utilisant Direct**.

Champs SSH : `host`, `user`, `port`, `identityFile`, `knownHostsFile`, `shell`. Shell Windows : powershell.exe par defaut ou pwsh.exe ; Linux : sh ou bash. SFTP et un dossier de destination existant sont requis pour upload SSH.

## Gestion Hyper-V et console optionnelle

```powershell
vmctl checkpoint -Vm win-vm -Name before-install
vmctl start -Vm win-vm
vmctl stop -Vm win-vm
vmctl restart -Vm win-vm
```

Stop demande un arret propre ; restart attend l'arret et redemarre. Aucune nouvelle tentative automatique, aucun reset force. Ces commandes ne dependent pas du transport invite.

La console Hyper-V WMI (`capabilities`, `screenshot`, `move`, `click`, `type`, `key`, `scroll`, `drag`) est distincte de l'execution des commandes. Sur la vraie VM win-vm, les captures, raccourcis clavier, saisie, clic et defilement ont ete verifies, notamment dans Securite Windows. Le decodeur RGB565 accepte aussi le prefixe de taille de quatre octets fourni par cet hote, apres validation de sa valeur exacte. Le glisser-deposer et tous les boutons souris ne sont pas encore verifies dans la VM. `capabilities` indique les peripheriques presents. Ces fonctions ne sont pas necessaires au transport Direct.

Console : droits administrateur ou `-Elevate` (UAC), console de base ; aucun controle du bureau hote. Les entrees exigent le JSON `-Frame` d'une capture valide : GUID/resolution/hash coherents, age maximal 120s, usage unique. Une nouvelle image est demandee apres chaque entree, sans rejeu automatique en cas d'echec. Details des arguments : `vmctl help`. `-Elevate` concerne uniquement cette console ; pour Direct, ouvrir le terminal hote avec les droits requis.

## Contrat et verification

- Codes : 0 succes, 2 configuration/lancement, 124 timeout ; SSH conserve ses codes dont 255. Erreurs PowerShell : 1 ; dernier code natif et `exit N` preserves.
- Delai 120s par defaut, doctor au maximum 30s. Timeout ou coupure ne garantissent pas l'arret de l'execution dans l'invite : verifier avant de relancer une installation.
- stdout/stderr sont collectes puis affiches. Pas d'interaction stdin ni de session de bureau via exec/run.
- run utilise -ExecutionPolicy Bypass uniquement pour son processus PowerShell ; aucun changement de politique dans le registre. Une strategie de groupe reste prioritaire. [Documentation Microsoft](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1).
- Scripts UTF-8, maximum 1 Mio. run cree un fichier temporaire dans l'invite, sans ses fichiers annexes ; pas encore de parametres de script. Le fichier est supprime a la fin normale/exception ; un exit explicite peut le laisser.
- upload de dossier exige `-Recursive`. La configuration s'edite par un seul processus ; register refuse de remplacer une cible.

```powershell
.\tests\Test-Vmctl.ps1
.\tests\Test-PowerShellDirect.ps1
.\tests\Test-ConsoleGuards.ps1
# Vraie VM, depuis un terminal hote avec les droits Hyper-V :
.\tests\Test-RealVm.ps1 -Vm win-vm -Credential $cred
```

Tests locaux : transport, selection Direct/SSH, Unicode, erreurs, exit, timeout, chemins, chiffrement DPAPI PS7/5.1 et gardes console. Ils ne prouvent pas un acces a une VM. Le test reel verifie identite de l'invite, transfert avec SHA-256, script Unicode, erreurs/codes et nettoyage de ses fichiers temporaires.

Atlas n'est jamais installe automatiquement par vmctl. `scripts/Test-AtlasPrerequisites.ps1` est un diagnostic ; `scripts/Install-Atlas.ps1` exige un lancement explicite et les conditions requises par son installateur.

[PowerShell Direct Microsoft](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell-direct)
[OpenSSH Windows Microsoft](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)

Validation dans win-vm le 5 octobre 2026 : doctor identifie WIN-VM et win-vm\vmctl-admin avec admin=true ; les 10 verifications du test reel Direct passent, y compris transfert SHA-256, script Unicode, code natif, erreur et nettoyage. Le diagnostic Atlas a ete execute via le CLI. La console screenshot/souris/clavier reste experimentale ; captures et entrees simples ont ete testees ensuite dans cette VM, comme indique plus haut.
