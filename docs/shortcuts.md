# Raccourcis du bureau

Depuis le lanceur `vmctl` installe avec `install.ps1` :

```powershell
vmctl shortcut install --name "VM - Fenetre" --mode windowed
vmctl shortcut install --name "VM - Plein ecran" --mode fullscreen
vmctl shortcut uninstall --name "VM - Fenetre"
vmctl shortcut uninstall --name "VM - Plein ecran"
```

`install` cree un raccourci `.lnk` dans le bureau Windows de l'utilisateur, y compris un bureau redirige vers OneDrive. Relancer la commande avec le meme nom remplace le raccourci gere par vmctl. `uninstall` retire ce raccourci ; le relancer reste sans effet. Un raccourci appartenant a une autre application n'est jamais remplace ou supprime.

Au double-clic, une petite fenetre demande uniquement de choisir la VM. La liste est relue depuis la configuration vmctl a chaque ouverture et contient les VM Windows Hyper-V utilisant PowerShell Direct, compatibles avec `streaming-open`. Ajouter une VM avec `vmctl register` ne necessite pas de recreer les raccourcis. Si une configuration personnalisee est souhaitable, passer `-Config PATH` a l'installation ; son chemin est conserve dans le raccourci.

Le choix appelle `vmctl streaming-open -Vm ALIAS -Mode windowed|fullscreen -Reconnect`. Annuler ne lance aucune connexion. Les erreurs s'affichent dans une boite de dialogue. Les fichiers et identifiants restent dans les emplacements habituels de vmctl. Aucune elevation n'est requise pour creer ou retirer les raccourcis.

Le plein ecran utilise la resolution de l'ecran principal, la souris relative et la capture des touches systeme. **Ctrl+Alt+Maj+Z** libere ou reprend la capture. Le mode fenetre conserve les preferences Moonlight. Voir [le streaming](streaming.md).

Les raccourcis pointent vers le runtime PowerShell et le script du depot : si le depot est deplace ou le runtime remplace, relancer `install.ps1` puis les commandes `shortcut install`.
