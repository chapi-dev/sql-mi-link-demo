# =====================================================================
# cleanup.ps1
# Elimina toda la infra de la demo (cuesta dinero!).
# Borra ambos resource groups en paralelo.
# =====================================================================

param(
    [string]$RgVm = "rg-sqlmilink-vm-fra",
    [string]$RgMi = "rg-sqlmilink-mi-esp",
    [string]$SubId = "<YOUR-SUB-ID>"
)

az account set --subscription $SubId

Write-Host "Borrando $RgVm y $RgMi (no-wait)..."
az group delete -n $RgVm --yes --no-wait
az group delete -n $RgMi --yes --no-wait

Write-Host "Borrado iniciado. Comprobar:"
Write-Host "  az group list --query ""[?name=='$RgVm' || name=='$RgMi'].name"" -o tsv"
