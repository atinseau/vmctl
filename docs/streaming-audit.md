# Audit du setup streaming

[Accueil](../README.md) · [Procedure streaming](streaming.md)

Audit du 6 octobre 2026, Apollo 0.4.6 et Moonlight 6.2.0.

## Nettoyage puis reinstallation

Dans `win-vm`, via les commandes publiques `vmctl run`, `exec` et `restart` : Apollo, SudoVDA, ViGEm, leurs pilotes, les configurations et caches invites, les regles pare-feu et les entrees PATH Apollo ont ete retires. Le reglage GpuVirtualizationFlags a ete restaure depuis sa sauvegarde. Les raccourcis et ports d'ecoute Apollo sont absents apres redemarrage.

Sur l'hote, `vmctl streaming-forget` a retire le profil de cette VM, son certificat serveur, son compte administrateur Apollo sous DPAPI et les sauvegardes de reglages associees. Moonlight reste installe ; son identite client et les preferences 120 FPS/souris absolue sont conservees. GPU-P reste a 25 % et la RTX 4090 est detectee dans l'invite sans erreur. Ce nettoyage ne modifie ni l'allocation GPU ni les checkpoints.

Le controle de stockage du 6 octobre a trouve zero checkpoint. Cette operation n'a execute aucune suppression de checkpoint.

Apollo a ensuite ete reinstalle a la demande de l'utilisateur. Le setup a reapplique le reglage de rendu, redemarre la VM, configure NVENC et refait le pairing par les commandes publiques. Moonlight est actuellement ouvert sur l'hote. Une reconnexion via `vmctl streaming-open -Vm win-vm -Reconnect` a ferme et rouvert le flux en environ sept secondes, sans nouvelle authentification. La fenetre, le premier paquet video et le client connecte a Apollo ont ete verifies ; 1080p120 et souris absolue sont demandes, sans mesure de la cadence reelle.

## Fragilites corrigees dans le code

| Probleme | Correction |
| --- | --- |
| Desinstallation silencieuse incomplete | Worker explicite pour SudoVDA, ViGEm, configurations et PATH. Verification des inscriptions restantes. |
| Moonlight ouvert conservant un cache d'appairage ancien | Fermeture propre du client inactif avant setup, refus d'un flux actif, reouverture ensuite. |
| Processus CLI de pairing termine trop tot | Attente du certificat enregistre, puis fermeture de sa fenetre ; verification par une nouvelle liste d'applications. |
| Nom Windows different du nom Hyper-V | Liaison persistante entre alias, GUID Hyper-V et UUID Apollo ; diagnostic et nettoyage par UUID. |
| Suppression d'un profil pouvant reapparaitre | Nettoyage des deux tableaux Qt hosts/hostsbackup en preservant les autres machines et leurs types de valeurs. |
| Identifiants Apollo anciens apres nettoyage | Suppression du seul fichier DPAPI de cet alias et des sauvegardes locales associees. |
| Preparation GPU-P encore manuelle | Sauvegarde du registre, retrait du bit 0x8 pour NVIDIA GPU-P, redemarrage si changement, verification de Direct et SudoVDA. |
| Mot de passe supprime avant de pouvoir reprendre un echec | Session elevee temporaire de 30 minutes ; relancer la meme commande reutilise la session vivante. Suppression du cache au succes/expiration. |
| Expiration JSON relue avec une date francaise | Conversion directe de DateTime/DateTimeOffset, sans reparsing de son texte localise. |
| Fenetre Moonlight admin et appel CLI bloque par des pipes herites | Lancement avec le jeton de la session Windows normale, sans heriter des pipes, et utilisation du journal natif Moonlight. |
| Titre de fenetre suppose contenir le nom de l'application | Verification du titre reel nom-Windows + Moonlight, du decodeur et de la reception video. |
| Verification de version lancant un second serveur dans le meme dossier | Inscription de l'installeur et version de l'API authentifiee ; aucun second sunshine.exe susceptible de perturber le journal du service. |

Le [code Moonlight](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/backend/computermanager.cpp) restaure hostsbackup au demarrage et conserve ses donnees en memoire. Le [CLI pair](https://github.com/moonlight-stream/moonlight-qt/blob/v6.2.0/app/gui/CliPair.qml) affiche une boite de confirmation apres succes et attend sa fermeture. L'[installeur officiel Apollo](https://github.com/ClassicOldSong/Apollo/blob/v0.4.6/cmake/packaging/windows_nsis.cmake) conserve certains composants et configurations par defaut en desinstallation silencieuse.

## Limites encore ouvertes

- Le reglage NVIDIA GPU-P est maintenant automatique et reversible. Il a ete teste sur cette VM ; sa generalisation reste a verifier sur d'autres GPUs et versions de Windows.
- `-Open` ajoute une preuve de reception video. Il ne prouve pas la qualite visuelle, le son, la latence, la cadence reelle ni les performances de jeu. Le resultat d'installation garde `streamTested=false` ; le rapport d'ouverture distinct indique `videoDeliveryVerified`.
- Le code 3010 et la sante SudoVDA sont maintenant traites. Une panne d'installation de pilote est signalee ; la recette ne tente pas toutes les reparations Windows possibles.
- Apollo a signale l'absence d'un peripherique audio par defaut. La recette n'installe pas encore de pilote audio virtuel ; le son reste a configurer/verifier.
- La premiere preparation de Windows et du compte administrateur avec mot de passe reste necessaire. Le PIN Windows Hello ne peut pas servir a PowerShell Direct.
- Les recettes doivent etre lancees une a la fois : il manque un verrou commun entre plusieurs installations et suppressions de profils Moonlight.
- Une configuration Apollo existante sans son secret local n'est pas ecrasee. Il faut recuperer cet acces ou choisir explicitement le nettoyage complet.

## Portee des tests

Le nettoyage, la reinstallation, le pairing, le redemarrage et une reconnexion ont ete executes sur la vraie VM. Des corrections ont ete faites pendant l'essai : il ne constitue pas un passage sans erreur du code final depuis une nouvelle VM de zero. Les tests locaux couvrent les gardes CLI, les profils Moonlight, les dates d'expiration JSON et les faux positifs de verification video. Les deux caches Windows des sessions de reprise ont ete supprimes et les deux workers sont termines.

Une validation de reproductibilite sur une autre VM reste necessaire. Le redemarrage complet de l'hote, une vraie mise a jour NVIDIA, le son et les performances de jeu restent des essais distincts. Les actions d'installation ont utilise vmctl ; les seules saisies humaines concernaient UAC et le mot de passe Windows. Les echecs initiaux ont provoque des authentifications supplementaires avant la correction du cache et de la date d'expiration.
