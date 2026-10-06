[Accueil](../README.md) · [Architecture](architecture.md)

## Moonlight sur l'hote et Apollo dans une VM Windows

```powershell
vmctl streaming-install -Vm win-vm -Open
# Autre VM deja enregistree :
vmctl streaming-install -Vm autre-vm
# Reutiliser une identification fournie et un dossier de rapports :
vmctl streaming-install -Vm autre-vm -CredentialFile C:\Temp\guest.clixml -ReportDirectory C:\Temp\streaming-report
```

Cette recette installe Moonlight 6.2.0 sur l'hote et Apollo 0.4.6 dans la VM avec leurs installateurs officiels et leurs empreintes SHA-256 GitHub. Elle active le service Apollo au demarrage, restreint les regles pare-feu Apollo au sous-reseau local, initialise le compte administrateur de l'interface et effectue l'appairage avec le CLI officiel Moonlight. Les commandes, transferts et appels de configuration dans la VM passent par vmctl. Cette commande ne cree pas d'adaptateur GPU-P. Si un unique GPU NVIDIA est deja affecte et sain dans l'invite, elle configure automatiquement Apollo pour NVENC et le mode headless, avec l'ecran virtuel seul pendant le flux et la resolution/frequence automatiques demandees par Moonlight, en conservant les autres reglages et une copie avant modification. Les checkpoints ne sont pas modifies.

Une elevation UAC est lancee si le terminal n'est pas administrateur. La commande retourne le PID et le fichier d'etat : lancement ne signifie pas installation terminee. Attendre `installed-and-paired` dans `streaming-status.json` ; `failed` contient le diagnostic. Le dossier par defaut est `%LOCALAPPDATA%\vmctl\reports\streaming\<Vm>`. Le mot de passe du compte de gestion est saisi dans une fenetre Windows. La session elevee reutilise ce cache DPAPI lors des reprises : relancer la meme commande apres un echec pendant ses 30 minutes de validite. Il est supprime au succes ou a l'expiration. Aucun PIN Moonlight n'est a saisir manuellement. `-Config` et les alias dont `vmName` differe sont transmis aux appels internes.

Avec un GPU-P NVIDIA sain, le setup sauvegarde GpuVirtualizationFlags puis retire son bit 0x8 si necessaire pour separer le rendu de la console Hyper-V. Les autres bits sont conserves. Ce changement ou un code installateur 3010 provoque un redemarrage via `vmctl`, une attente de PowerShell Direct et une nouvelle verification Apollo/SudoVDA. Le meme mot de passe est reutilise. Une relance avec un reglage deja applique ne redemarre pas la VM pour cette raison.

Pour ouvrir ensuite la VM depuis un terminal normal :

```powershell
vmctl streaming-open -Vm win-vm
# Fermer proprement le flux de cette VM puis le rouvrir :
vmctl streaming-open -Vm win-vm -Reconnect
```

`streaming-open` utilise le UUID Apollo conserve, verifie la liste d'applications et ouvre Virtual Display. Resolution, FPS et souris absolue suivent les preferences Moonlight existantes ; le flux utilise H.264 dans une fenetre. Une session deja ouverte et identifiee est reutilisee ; une autre session est refusee. Le setup eleve lance le client avec le jeton de la session Windows normale. La reconnexion ne demande ni UAC ni mot de passe Windows. Son journal reste dans le dossier TEMP Moonlight.

Avec `-Open`, le resultat final est `stream-window-open`. La fenetre doit porter le nom de cette VM et le journal doit montrer un decodeur choisi puis la reception du premier paquet video. Un simple processus Moonlight ou son test interne de decodeur ne suffit pas. Cela ne prouve ni la cadence reelle ni la qualite de l'image ou du son.

Validation du 6 octobre : reinstallation apres nettoyage, preparation du rendu et redemarrage automatiques, nouveau pairing, ouverture NVENC 1080p120/souris absolue puis reconnexion en environ sept secondes depuis un terminal normal. Les caches Windows des essais ont ete supprimes et les sessions elevees terminees. Des erreurs de verification et de reprise ont ete corrigees pendant cet essai ; ce n'est pas une validation d'une nouvelle VM de zero ni de toutes les configurations GPU.

Le mot de passe genere pour l'interface Apollo est distinct du mot de passe Windows. Il est conserve chiffre dans `%LOCALAPPDATA%\vmctl\credentials\apollo-<Vm>.clixml`, afin que la recette puisse etre relancee et que le proprietaire accede aux reglages. Pour le copier depuis une boite de dialogue locale, sans l'afficher dans le terminal :

```powershell
vmctl streaming-access -Vm win-vm
```

Pour consulter les clients appaires, les reglages video et les journaux sans nouvelle identification Windows ni UAC :

```powershell
vmctl streaming-status -Vm win-vm
vmctl streaming-status -Vm win-vm -Diagnostics
```

Ces appels utilisent le compte Apollo chiffre et verifient son certificat contre celui deja conserve par Moonlight. L'adresse locale est reprise du cache de decouverte Moonlight ; ouvrir Moonlight actualise ce cache apres un changement d'IP. `-HostName IPv4` permet de choisir une adresse deja associee a cet hote appaire. Les rapports n'exposent pas les mots de passe ni les certificats clients.

L'appairage Moonlight est permanent tant que ses identifiants utilisateur et le certificat Apollo sont conserves. Il n'y a pas de PIN a renouveler a chaque ouverture. Le 6 octobre, deux nouveaux processus CLI ont liste les applications sans nouvel appairage ; apres fermeture et relance de l'ancienne instance graphique, l'utilisateur a confirme l'acces direct.

Pour diagnostiquer un ecran noir, deconnecter le flux avant de modifier les reglages :

```powershell
vmctl streaming-display-fix -Vm win-vm
vmctl streaming-display-restore -Vm win-vm
vmctl streaming-video-test -Vm win-vm -Encoder software
vmctl streaming-video-test -Vm win-vm -Encoder nvenc
vmctl streaming-video-test -Vm win-vm -Encoder software -DefaultAdapter -ConsoleDisplay
vmctl streaming-video-restore -Vm win-vm
```

La correction d'affichage demande un ecran principal, ou l'ecran virtuel seul si headless et NVIDIA sont configures, avec retablissement a la deconnexion et resolution/frequence auto. Elle remet les journaux au niveau info. display-restore restaure ces cinq champs depuis la premiere sauvegarde. Le test video modifie encoder/hevc_mode/av1_mode/min_log_level. `-DefaultAdapter` retire temporairement le GPU force ; `-ConsoleDisplay` desactive headless et les changements de topologie pour tester Desktop sur le moniteur Hyper-V. `-OnlyDisplay` active headless et ensure_only_display ; ces deux options sont incompatibles. video-restore remet les quatre champs video et adapter_name/headless_mode/output_name/dd_configuration_option. Chaque famille conserve sa premiere sauvegarde DPAPI locale et redemarre Apollo. Une session Moonlight connectee bloque ces modifications.

Diagnostic du 6 octobre : le passage en ecran principal et l'encodage logiciel n'ont pas suffi quand la console Hyper-V etait associee au GPU partage. Le script `scripts/Set-GuestConsoleRendering.ps1` sauvegarde le registre invite puis retire le bit 0x8 de GpuVirtualizationFlags, selon [la documentation Microsoft](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/gpu-paravirtualization#virtual-render-device-vrd). Apres redemarrage, le rendu/capture du moniteur Hyper-V utilise Microsoft Basic Render Driver, l'encodage libx264 cesse de se recreer en boucle et la capture native montre l'ecran de verrouillage. La RTX 4090 reste attribuee et saine. L'utilisateur a confirme une image visible dans Moonlight avec le moniteur Hyper-V, libx264 et le decodage logiciel. Le test suivant a identifie le conflit avec le moniteur Hyper-V encore actif : ensure_only_display a supprime les reinitialisations permanentes et l'utilisateur a confirme le bureau visible et fluide avec h264_nvenc en 1080p60. Les reglages de topologie sont restaures a la fin du flux. La preparation du registre et de l'ecran virtuel seul est maintenant incluse dans streaming-install pour un GPU-P NVIDIA sain ; gpu-setup seul ne modifie pas ce registre invite.

Pour executer ou annuler ce test avec un seul compte de gestion invite deja fourni, depuis le terminal hote eleve :

```powershell
vmctl upload -Vm win-vm -Credential $cred -Source .\scripts\Set-GuestConsoleRendering.ps1 -Destination C:/ProgramData/vmctl/streaming/Set-GuestConsoleRendering.ps1
vmctl exec -Vm win-vm -Credential $cred -Command '& C:\ProgramData\vmctl\streaming\Set-GuestConsoleRendering.ps1 -Mode base'
vmctl restart -Vm win-vm
# Restauration du registre, puis redemarrage :
vmctl exec -Vm win-vm -Credential $cred -Command '& C:\ProgramData\vmctl\streaming\Set-GuestConsoleRendering.ps1 -Mode restore'
vmctl restart -Vm win-vm
```

Pour demarrer le profil teste avec le CLI officiel Moonlight (sur l'hote, apres appairage) :

```powershell
& 'C:\Program Files\Moonlight Game Streaming\Moonlight.exe' stream win-vm.local 'Virtual Display' --1080 --fps 120 --video-codec H.264 --absolute-mouse --game-optimization --display-mode windowed
```

La resolution suit la demande Moonlight a chaque nouvelle connexion ; redimensionner sa fenetre ne renegocie pas automatiquement la resolution Windows. Le 6 octobre, les preferences Moonlight de cet utilisateur ont aussi ete conservees a 120 FPS et souris absolue. Le flux NVENC 1080p120 est reste actif sans boucle de reinitialisation pendant plus d'une minute ; la fluidite et l'image avaient ete confirmees par l'utilisateur en 1080p60. Le moniteur virtuel indique environ 144 Hz : ce taux d'affichage et les 120 FPS demandes au flux sont deux reglages distincts. Une faible charge 3D sur un bureau au repos ne mesure pas l'utilisation du moteur NVENC. Les performances d'un jeu ne sont pas validees.
Les rapports indiquent l'adresse de l'interface `https://<IP>:47990`. Le certificat initial est autosigne. Les appels d'initialisation et d'appairage utilisent une exception TLS limitee a curl sur 127.0.0.1 dans la VM, jamais une modification globale de la validation TLS. Une configuration Apollo existante sans son fichier DPAPI exige de fournir/reconfigurer volontairement son acces ; elle n'est pas ecrasee. Une installation Sunshine existante est refusee pour eviter son remplacement implicite.

Validation reelle du 5 octobre 2026 : Moonlight 6.2.0, Apollo 0.4.6, ApolloService Running/Auto, SudoVDA OK, appairage et liste des trois applications verifies dans win-vm. Un vrai flux Virtual Display H.264 1280x720 a ete recu et decode sans GPU physique attribue. Ce test ne valide ni le son, ni les performances de jeu, ni la persistance apres redemarrage.

## Nettoyer Apollo et le profil Moonlight

Fermer Moonlight sur l'hote. Depuis le terminal hote administrateur, utiliser le meme compte invite pendant toute l'operation :

```powershell
$cred = Get-Credential -UserName vmctl-admin
vmctl run -Vm ma-vm -Credential $cred -File .\scripts\Uninstall-ApolloGuest.ps1
vmctl restart -Vm ma-vm
vmctl streaming-forget -Vm ma-vm
```

Le worker de nettoyage complet retire aussi SudoVDA et ViGEm : verifier avant de le lancer que ces composants ne sont pas partages avec d'autres applications dans la VM. Il restaure le reglage de rendu cree par vmctl, retire les fichiers/configurations Apollo et ses entrees PATH. Il laisse Atlas et GPU-P en place. Le redemarrage libere les pilotes retires.

`streaming-forget` s'execute sur l'hote sans UAC ni mot de passe invite. Il efface uniquement le profil et le compte API Apollo de cette cible. La liaison UUID est prioritaire ; pour une installation ancienne sans liaison et plusieurs noms identiques, `-HostName IPv4` selectionne le profil par son adresse connue. L'identite du client Moonlight, les autres machines et les preferences sont conservees. Ouvrir Moonlight pendant cette mutation est refuse pour eviter de reecrire un ancien cache.

Le setup ferme maintenant un Moonlight inactif avant appairage et le rouvre ensuite ; deconnecter un flux actif avant de lancer la recette. [Audit et limites du setup automatique](streaming-audit.md).

## Automatisation GPU-P NVIDIA

Pour une nouvelle VM Windows deja enregistree, utiliser un terminal administrateur : gpu-setup puis streaming-install. La premiere commande ne demande pas de mot de passe invite ; la seconde utilise une seule identification Windows pour installer, configurer et appairer Apollo. Si streaming-install a ete execute avant gpu-setup, le relancer ensuite configure NVENC sans refaire les installations deja presentes.

```powershell
vmctl gpu-setup -Vm win-vm -GpuName 'NVIDIA GeForce RTX 4090' -GpuPercent 25 -Elevate
# Depuis un terminal deja administrateur, -Elevate n'est pas necessaire.
vmctl gpu-status -Vm win-vm -Elevate
vmctl restart -Vm win-vm -TimeoutSeconds 900
```

Le pourcentage est conserve dans `%ProgramData%\vmctl\gpu\<GUID>\configuration.json`, champ `percent`, et applique aux budgets de l'adaptateur Hyper-V. Pour win-vm, le GUID est `82e1dde7-67c7-4ff0-956d-00fb4ee636e3` et `percent` vaut 25. `gpu-status` montre les valeurs appliquees ; relancer `gpu-setup -GpuPercent 50` change l'allocation en arretant proprement la VM. Editer le JSON seul ne change pas l'adaptateur. Ce pourcentage exprime des budgets de ressources Hyper-V ; il ne garantit pas une fraction identique des performances ni une quantite physique de VRAM reservee.

gpu-setup choisit exactement le GPU NVIDIA demande et son identite PCI, arrete proprement la VM, ajoute GPU-P, fixe les budgets VRAM/Encode/Decode/Compute, desactive la memoire dynamique et regle le MMIO. Le pilote actuel de l'hote est copie dans HostDriverStore et ses bibliotheques NVIDIA System32/SysWOW64 dans l'invite. Les empreintes SHA-256 de chaque fichier copie sont comparees avant le demarrage. Seul le disque actif est modifie ; les checkpoints existants sont conserves. Cette recette exige une VM Windows generation 2 avec un seul disque systeme.

Le controleur installe une tache Windows au demarrage de l'hote, sous SYSTEM, avec un delai de 45 secondes. Son code est copie dans Program Files et sa configuration dans ProgramData ; ces deux emplacements sont limites a SYSTEM/Administrateurs. Aucun mot de passe invite n'est utilise ou conserve par cette tache. Le demarrage automatique natif de cette VM est remplace par ce controleur : apres controle/synchronisation, il demarre la VM. L'arret automatique de la VM devient un arret Windows propre plutot qu'une sauvegarde RAM.

Une empreinte de l'identite PCI, de la version du pilote et de l'inventaire des fichiers detecte les changements. `vmctl start` et `vmctl restart` utilisent le meme controleur pour les VM configurees. Le pilote n'est pas recopie si l'inventaire et le disque actif sont inchanges. Si une mise a jour intervient pendant que la VM tourne, aucun arret force ni copie dans son disque en cours d'utilisation n'est effectue : la synchronisation est realisee au prochain demarrage gere. Il n'y a pas de surveillance permanente ni de redemarrage impose apres une mise a jour NVIDIA.

Le montage du disque est protege par un verrou par GUID, exige la VM Off et un disque non attache, identifie une partition Windows unique et refuse les jonctions/liens dans les chemins invites. Le montage est retire dans finally. Les budgets UInt64 sont calcules en decimal pour eviter les erreurs de precision sur les valeurs NVENC maximales. Une identite PCI differente ou un adaptateur inattendu bloque le demarrage avec un diagnostic. Une restauration du checkpoint Atlas sans GPU exige donc de reconfigurer explicitement avec gpu-setup ou de retirer cette gestion avec gpu-remove.

Pour revenir aux reglages Hyper-V precedents, VM arretee :

```powershell
vmctl stop -Vm win-vm
vmctl gpu-remove -Vm win-vm -Elevate
```

gpu-remove retire l'adaptateur et la tache, puis restaure les reglages MMIO, memoire et demarrage sauvegardes. Les fichiers NVIDIA copies dans Windows sont conserves pour ne pas supprimer des DLL qui pourraient etre utilisees par un autre pilote ; les checkpoints ne sont pas touches. gpu-task-test lance la tache deja enregistree et attend son code de sortie ; une VM arretee sera demarree par cette verification. gpu-setup valide aussi ce chemin SYSTEM lorsqu'il doit relancer une VM qui tournait avant la configuration. Les erreurs et le dernier rapport sont dans `%ProgramData%\vmctl\gpu\<GUID>`.

Validation locale : Test-GpuPlanning.ps1 verifie 17 cas de calcul UInt64, detection des changements et refus de chemins dangereux ; Test-Vmctl.ps1 verifie 47 cas dont les gardes avant mutation. Sur win-vm, la RTX 4090 est detectee sans erreur, nvEncodeAPI64.dll correspond au pilote hote, Apollo cree h264_nvenc sur ce GPU et Moonlight recoit un flux H.264 1920x1080. Le redemarrage via vmctl et le lancement par la tache SYSTEM ont reussi, sans recopier les pilotes inchanges. Le 6 octobre, le diagnostic a corrige l'image noire : GpuVirtualizationFlags=0 dans l'invite puis ecran virtuel seul (ensure_only_display) dans Apollo. L'utilisateur a confirme le bureau visible et fluide en NVENC 1080p60. Un nouveau flux demande 1080p120 avec souris absolue ; ce n'est pas une mesure de performances de jeu. Ces essais ne mesurent pas les performances de jeu ; le son et CUDA ne sont pas valides. Un redemarrage complet de l'hote et une vraie mise a jour de pilote NVIDIA ne sont pas impliques par ces tests.

## Recherches GPU-P pour Hyper-V

Le diagnostic `scripts/Test-StreamingGpuHost.ps1 -Vm <nom Hyper-V>` est en lecture seule. Sur cet hote Windows 11 Pro 24H2, la RTX 4090 et le GPU AMD integre sont listes par Get-VMHostPartitionableGpu ; win-vm est en 25H2 et ne possede aucun adaptateur GPU-P. Les valeurs TotalVRAM sont des unites de ressources exposees par le pilote et ne doivent pas etre prises directement pour des octets de VRAM physique.

Pour une nouvelle VM, [Enhanced-GPU-PV](https://github.com/timminator/Enhanced-GPU-PV) automatise Windows, GPU-P, Sunshine et un ecran virtuel. Pour une VM existante, [Simple-GPU-P](https://github.com/PrzemekWolw/Simple-GPU-P) gere ajout, allocation, suppression et mise a jour des pilotes. Ces projets sont utiles comme references, mais leurs derniers changements datent de 2024. [Easy-GPU-PV](https://github.com/jamesstringer90/Easy-GPU-PV) est archive depuis juin 2026. [Sunshine-AIO](https://github.com/LeGeRyChEeSe/Sunshine-AIO) automatise une pile Sunshine, mais les ecrans virtuels supplementaires sont inutiles avec Apollo/SudoVDA.

La piste adaptee ici est de conserver la VM Atlas et SudoVDA, ajouter un adaptateur GPU-P lie explicitement a la RTX 4090, definir une allocation de depart (par exemple 25 %), copier les fichiers du pilote hote requis dans HostDriverStore et verifier Direct3D/NVENC dans l'invite. La configuration d'adaptateur appartient a la VM ; un redemarrage ordinaire ne demande pas de refaire l'allocation. La partie fragile est la coherence des pilotes apres une mise a jour NVIDIA sur l'hote : verifier une empreinte/version, synchroniser seulement en cas de changement, puis demarrer la VM. Un coordinateur de demarrage doit eviter une course avec le demarrage automatique Hyper-V et refuser de modifier un disque en cours d'utilisation. Le coordinateur decrit dans la section precedente est maintenant implemente ; consulter le rapport GPU pour les validations effectivement executees.

Tester separement arret/demarrage de la VM, redemarrage de la VM, redemarrage de l'hote et mise a jour du pilote. Les sources communautaires recommandent des versions Windows correspondantes entre hote et invite ; l'ecart 24H2/25H2 actuel merite donc un essai avant toute promesse de stabilite. Ne pas desactiver la console Hyper-V de secours avant verification du stream GPU. DDA dedie le GPU entier ; il ne repond pas au besoin de fractionnement.

[Microsoft precise que DDA/GPU-P ne sont pas pris en charge sur materiel de bureau et Windows 10/11 Pro](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-hyper-v-gpu-assignment-partitioning-passthrough-issues). Le support officiel GPU-P est sur Windows Server 2025 et GPUs compatibles, pas sur cette configuration Windows 11 + GeForce.
