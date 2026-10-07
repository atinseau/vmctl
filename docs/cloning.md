# Clone Hyper-V pour le laboratoire

Le module expose l'operation interne `Invoke-VmctlHyperV -Action clone`, utilisable via le broker privilegie. Elle execute uniquement `scripts/Copy-HyperVCheckpoint.ps1` depuis le depot. Il n'existe pas encore de commande publique `vmctl clone`.

La source doit etre arretee, sans adaptateur GPU-P, et identifiee par son nom et son GUID. Le checkpoint choisi doit contenir un seul disque VHDX dynamique sans parent. Le worker refuse un nom de VM ou un dossier destination existant ; il copie le disque entier et cree une VM generation 2 avec un nouveau GUID, une nouvelle carte reseau et un nouveau protecteur TPM. Il conserve la memoire, les processeurs, le switch et les reglages Secure Boot. `clone-state.json` indique la phase atteinte ; un echec ne supprime pas les fichiers crees.

Apres copie, reconfigurer le GPU-P de la source et du clone avec `gpu-setup`, puis demarrer les deux VM. La copie conserve Windows, ses comptes et ses donnees : elle ne generalise pas Windows avec Sysprep. Un disque chiffre doit pouvoir demarrer avec le nouveau TPM ; dans l'essai du laboratoire, la protection BitLocker de la source etait suspendue avant copie.

`scripts/Initialize-ClonedApolloGuest.ps1`, execute uniquement dans le clone par `vmctl run`, renomme Windows et reinitialise l'identite Apollo. Il exige le nom Windows d'origine, sauvegarde la configuration et les anciennes identites dans un dossier reserve aux administrateurs et a SYSTEM, puis demande un redemarrage. Ses valeurs par defaut sont `win-vm-1` vers `win-vm-2`. Enregistrer ensuite le clone avec son propre GUID et ses identifiants Windows, et executer `streaming-install` pour son nouvel appairage.

L'installation verifie le certificat public Apollo via PowerShell Direct vers cette VM. Elle peut reparer un certificat Moonlight absent ou invalide ; un certificat existant valide et different est refuse. Les preferences et l'identite du client Moonlight restent conservees.

Validation du 7 octobre 2026 : checkpoint natif de `win-vm-1`, copie initiale des disques avec SHA-256 identique, puis deux VM actives avec GPU-P a 25 % et identites Apollo distinctes. Le raccourci existant **VM - Fenetre** ouvre `win-vm-2` via le meme CLI, avec bureau visible et reception video en 1920x1080 a 120 FPS par NVENC. Les 120 FPS sont la cadence demandee, pas une mesure de performances de jeu.

Avant la premiere connexion Windows du clone, Virtual Display donnait une image noire. Le profil de recuperation `streaming-video-test -Encoder software -DefaultAdapter -ConsoleDisplay`, puis `streaming-open -Application Desktop -Reconnect`, a affiche l'ecran de connexion. Apres connexion manuelle avec `admin`, `streaming-video-restore` a retabli NVENC et le lancement habituel Virtual Display a affiche le bureau.
