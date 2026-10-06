# Audit du setup streaming

[Accueil](../README.md) · [Procedure streaming](streaming.md)

Audit du 6 octobre 2026, Apollo 0.4.6 et Moonlight 6.2.0.

## Nettoyage reel termine

Dans `win-vm`, via les commandes publiques `vmctl run`, `exec` et `restart` : Apollo, SudoVDA, ViGEm, leurs pilotes, les configurations et caches invites, les regles pare-feu et les entrees PATH Apollo ont ete retires. Le reglage GpuVirtualizationFlags a ete restaure depuis sa sauvegarde. Les raccourcis et ports d'ecoute Apollo sont absents apres redemarrage.

Sur l'hote, `vmctl streaming-forget` a retire le profil de cette VM, son certificat serveur, son compte administrateur Apollo sous DPAPI et les sauvegardes de reglages associees. Moonlight reste installe ; son identite client et les preferences 120 FPS/souris absolue sont conservees. GPU-P reste a 25 % et la RTX 4090 est detectee dans l'invite sans erreur. Ce nettoyage ne modifie ni l'allocation GPU ni les checkpoints.

Le controle de stockage du 6 octobre a trouve zero checkpoint. Cette operation n'a execute aucune suppression de checkpoint.

## Fragilites corrigees dans le code

| Probleme | Correction |
| --- | --- |
| Desinstallation silencieuse incomplete | Worker explicite pour SudoVDA, ViGEm, configurations et PATH. Verification des inscriptions restantes. |
| Moonlight ouvert conservant un cache d'appairage ancien | Fermeture propre du client inactif avant setup, refus d'un flux actif, reouverture ensuite. |
| Processus CLI de pairing termine trop tot | Attente du certificat enregistre, puis fermeture de sa fenetre ; verification par une nouvelle liste d'applications. |
| Nom Windows different du nom Hyper-V | Liaison persistante entre alias, GUID Hyper-V et UUID Apollo ; diagnostic et nettoyage par UUID. |
| Suppression d'un profil pouvant reapparaitre | Nettoyage des deux tableaux Qt hosts/hostsbackup en preservant les autres machines et leurs types de valeurs. |
| Identifiants Apollo anciens apres nettoyage | Suppression du seul fichier DPAPI de cet alias et des sauvegardes locales associees. |

Le [code Moonlight](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/backend/computermanager.cpp) restaure hostsbackup au demarrage et conserve ses donnees en memoire. Le [CLI pair](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/gui/CliPair.qml) affiche une boite de confirmation apres succes et attend sa fermeture. L'[installeur officiel Apollo](https://github.com/ClassicOldSong/Apollo/blob/v0.4.6/cmake/packaging/windows_nsis.cmake) conserve certains composants et configurations par defaut en desinstallation silencieuse.

## Limites encore ouvertes

- Le contournement GpuVirtualizationFlags necessaire pour l'ecran noir sur cette VM n'est pas automatique. Il reste un diagnostic explicite et reversible ; sa generalisation exige un essai sur une nouvelle VM.
- Un setup reussi valide services, API, appairage et liste d'applications. Il ne prouve pas l'image, le son, la latence, la cadence reelle ni les performances de jeu. Le resultat garde `streamTested=false`.
- L'installation ne traite pas encore integralement un redemarrage demande par les installateurs ou un pilote d'affichage installe mais non fonctionnel. Ces cas exigent une verification de l'invite avant le premier flux.
- La premiere preparation de Windows et du compte administrateur avec mot de passe reste necessaire. Le PIN Windows Hello ne peut pas servir a PowerShell Direct.
- Les recettes doivent etre lancees une a la fois : il manque un verrou commun entre plusieurs installations et suppressions de profils Moonlight.
- Une configuration Apollo existante sans son secret local n'est pas ecrasee. Il faut recuperer cet acces ou choisir explicitement le nettoyage complet.

## Portee des tests

Le nettoyage et le redemarrage ont ete executes sur la vraie VM. Les tests locaux couvrent les gardes CLI et la conservation des profils Moonlight avec des fixtures de registre isolees. Le setup modifie, notamment la nouvelle attente de pairing, n'a pas encore ete rejoue de bout en bout apres desinstallation : la VM reste volontairement sans Apollo, conformement a la demande de nettoyage.

Une validation de reproductibilite doit repartir de cet etat, lancer `streaming-install`, verifier un flux NVENC, fermer/rouvrir Moonlight sans PIN, puis redemarrer la VM. Le redemarrage complet de l'hote et une mise a jour reelle du pilote NVIDIA restent des essais distincts.
