# =====================================================================
# cleanup.ps1
# Elimina la infra de la demo. Borra ambos resource groups en paralelo.
# Recordar: el Recovery Services Vault (si se desplegó) puede tener
# soft-delete habilitado por policy y retener items eliminados durante
# el periodo de retención configurado (típicamente 14 días).
# =====================================================================

param(
    [Parameter(Mandatory)] [string]$SubId,
    [string]$RgVm = "rg-milink-vm",
    [string]$RgMi = "rg-milink-mi"
)

az account set --subscription $SubId

Write-Host "Borrando $RgVm y $RgMi (no-wait)..."
az group delete -n $RgVm --yes --no-wait
az group delete -n $RgMi --yes --no-wait

Write-Host "Borrado iniciado. Comprobar:"
Write-Host "  az group list --query ""[?name=='$RgVm' || name=='$RgMi'].name"" -o tsv"
