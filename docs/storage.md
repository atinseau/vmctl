[Accueil](../README.md) · [Architecture](architecture.md)

## Espace disque Hyper-V

`vmctl storage -Vm win-vm` mesure le disque actif et sa chaine de checkpoints. Pour recuperer les blocs inutilises apres nettoyage et ReTrim dans l'invite : `vmctl stop -Vm win-vm`, puis `vmctl compact -Vm win-vm -TimeoutSeconds 900`, puis `vmctl start -Vm win-vm`. compact exige une VM arretee, verifie son GUID configure, monte seulement les disques actifs en lecture seule et utilise Optimize-VHD Retrim puis Full. Les checkpoints et la capacite virtuelle restent inchanges. Une compaction peut reussir sans gain si les blocs sont toujours necessaires.

Sur demande explicite de suppression des points de retour, ajouter `-RemoveCheckpoints` a compact. Cette option supprime tous les checkpoints de cette VM via Remove-VMSnapshot, attend la fusion dans le disque de base, puis compacte. L'etat Windows courant est conserve ; les anciens points de retour sont perdus. `-DisableAutomaticCheckpoints` (compact/checkpoint uniquement) empeche la creation automatique de nouveaux points. Un nouveau point de reference peut ensuite etre cree avec `vmctl checkpoint -Vm win-vm -Name atlas-initial`, de preference VM eteinte pour eviter une sauvegarde de memoire.

Pour une automatisation sans saisie a chaque appel, on peut exporter volontairement un PSCredential avec `Export-Clixml` puis fournir `-CredentialFile PATH`. Sous Windows le secret est chiffre pour le meme utilisateur sur le meme ordinateur. Garder ce fichier hors du depot et le supprimer quand il n'est plus utile. Le compte conserve les memes droits, meme apres elevation UAC avec ce meme utilisateur.

Configuration minimale :

```json
{
  "schemaVersion": 1,
  "targets": {
    "win-vm": {
      "os": "windows",
      "hypervisor": "hyperv",
      "vmName": "win-vm",
      "transport": "psdirect",
      "user": "win-vm\\vmctl-admin"
    }
  }
}
```

`vmId` optionnel fixe aussi le GUID ; nom et GUID doivent correspondre. Une cible Direct n'a pas besoin de `host`. `user` sert a pre-remplir l'identification. Aucun identifiant n'est necessaire pour start/stop/checkpoint, uniquement les droits Hyper-V sur l'hote.
