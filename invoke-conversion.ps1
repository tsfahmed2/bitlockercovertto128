
<#
 .SYNOPSIS
    Encrypts OS drive with bitlocker, adds a recovery password and backs up to Azure AD 

You will need to test this thoroughly, and change to aes 256 where necessary. If your PCs are not azure AD joined, remove the last bit to back up the recovery key to AAD
 
#>




[cmdletbinding()]
param(
  [ValidateNotNullOrEmpty()]
  [string]
 $OSDrive = $env:SystemDrive,

  [parameter()]
  [string]
  [ValidateSet('XtsAes256', 'XtsAes128', 'Aes256', 'Aes128')]
 $encryption_strength = 'XtsAes128'
)

#endregion Parameters

#====================================================================================================
#                                           Initialize
#====================================================================================================
#region  Initialize

# Provision new source for Event log

#endregion  Initialize

#====================================================================================================
#                                             Functions
#====================================================================================================


function Get-TPMStatus 
{
 # Returns true/false if TPM is ready
 $tpm = Get-Tpm
 if ($tpm.TpmReady -and $tpm.TpmPresent -eq $true) 
  {
 return $true
  }
 else 
  {
 return $false
  }
}

function Test-RecoveryPasswordProtector() 
{
 $AllProtectors = (Get-BitLockerVolume -MountPoint $OSDrive).KeyProtector
 $RecoveryProtector = ($AllProtectors | Where-Object {
 $_.KeyProtectorType -eq 'RecoveryPassword' 
  })
 if (($RecoveryProtector).KeyProtectorType -eq 'RecoveryPassword') 
  {
 Write-Output 'Recovery password protector detected'
 return $true
  }
 else 
  {
 Write-Output 'Recovery password protector not detected'
 return $false
  }
}

function Test-TpmProtector() 
{
 $AllProtectors = (Get-BitLockerVolume -MountPoint $OSDrive).KeyProtector
 $RecoveryProtector = ($AllProtectors | Where-Object {
 $_.KeyProtectorType -eq 'Tpm' 
  })
 if (($RecoveryProtector).KeyProtectorType -eq 'Tpm') 
  {
 Write-Output 'TPM protector detected'
 return $true
  }
 else 
  {
 Write-Output 'TPM protector not detected'
 return $false
  }
}

function Set-RecoveryPasswordProtector() 
{
 try 
  {
 Add-BitLockerKeyProtector -MountPoint $OSDrive -RecoveryPasswordProtector 
 Write-Output 'Added recovery password protector to bitlocker enabled drive'
  }
 catch 
  {
 throw Write-Output 'Error adding recovery password protector to bitlocker enabled drive' 
  }
}

function Set-TpmProtector() 
{
 try 
  {
 Add-BitLockerKeyProtector -MountPoint $OSDrive -TpmProtector
 Write-Output 'Added TPM protector to bitlocker enabled drive'
  }
 catch 
  {
 throw Write-Output 'Error adding TPM protector to bitlocker enabled drive'
  }
}


function Backup-RecoveryPasswordProtector() 
{
 $AllProtectors = (Get-BitLockerVolume -MountPoint $OSDrive).KeyProtector
 $RecoveryProtector = ($AllProtectors | Where-Object {
 $_.KeyProtectorType -eq 'RecoveryPassword' 
  })

 try 
  {
    BackupToAAD-BitLockerKeyProtector -MountPoint $OSDrive -KeyProtectorId $RecoveryProtector.KeyProtectorID
 Write-Output 'BitLocker recovery password has been successfully backup up to Azure AD'
  }
 catch 
  {
 throw Write-Output 'Error backing up recovery password to Azure AD.'
  }
}

function Invoke-Encryption() 
{
 # Test that TPM is present and ready
 try 
  {
 Write-Output 'Checking TPM Status before attempting encryption'
 if (Get-TPMStatus -eq $true) 
    {
 Write-Output 'TPM Present and Ready. Beginning encryption process'
    }
  }
 catch 
  {
 throw Write-Output 'Issue with TPM. Exiting script'
  }

 # Encrypting OS drive
 try 
  {
 Write-Output 'Enabling bitlocker with Recovery Password protector and method'
 Enable-BitLocker -MountPoint $OSDrive -SkipHardwareTest -UsedSpaceOnly -EncryptionMethod $encryption_strength -RecoveryPasswordProtector
 Write-Output "Bitlocker enabled encryption method $OSDrive, $encryption_strength"
  }
 catch 
  {
 throw Write-Output "Error enabling bitlocker on OS drive"
  }
}

function Invoke-UnEncryption() 
{
 # Call disable-bitlocker command, reboot after unencryption?
 try 
  {
 Write-Output "Unencrypting bitlocker enabled drive"
 Disable-BitLocker -MountPoint $OSDrive
  }
 catch 
  {
 throw Write-Output "Issue unencrypting bitlocker enabled drive"
  }
}

function Remove-RecoveryPasswordProtectors() 
{
 # Remove all recovery password protectors
 try 
  {
 $RecoveryPasswordProtectors = (Get-BitLockerVolume -MountPoint $env:SystemDrive).KeyProtector | Where-Object {
 $_.KeyProtectorType -contains 'RecoveryPassword' 
    }
 foreach ($PasswordProtector in $RecoveryPasswordProtectors) 
    {
 Remove-BitLockerKeyProtector -MountPoint $OSDrive -KeyProtectorId $($PasswordProtector).KeyProtectorID
 Write-Output "Removed recovery password protector with ID:$PasswordProtector"
    }
  }
 catch 
  {
 Write-Output "Error removing recovery password protector"
  }
}

function Remove-TPMProtector() 
{
 # Remove TPM password protector
 try 
  {
 $TPMProtector = (Get-BitLockerVolume -MountPoint $env:SystemDrive).KeyProtector | Where-Object {
 $_.KeyProtectorType -contains 'Tpm' 
    }
 Remove-BitLockerKeyProtector -MountPoint $OSDrive -KeyProtectorId $($TPMProtector).KeyProtectorID
 Write-Output "Removed TPM Protector with ID"
  }
 catch 
  {
 Write-Output "Error removing recovery password protector"
  }
}


#endregion Functions


#====================================================================================================
#                                             Main-Code
#====================================================================================================
#region MainCode

# Start
Write-Output "Running bitlocker intune encryption script"

# Check if OS drive is ecrpyted with parameter $encryption_strength
if ((Get-BitLockerVolume -MountPoint $OSDrive).VolumeStatus -eq 'FullyEncrypted' -and (Get-BitLockerVolume -MountPoint $OSDrive).EncryptionMethod -eq $encryption_strength) 
{
 Write-Output "BitLocker is already enabled on and the encryption method is correct $OSDrive"
}

# Drive is encrypted but does not meet set encryption method
elseif ((Get-BitLockerVolume -MountPoint $OSDrive).VolumeStatus -eq 'FullyEncrypted' -and (Get-BitLockerVolume -MountPoint $OSDrive).EncryptionMethod -ne $encryption_strength) 
{
 Write-Output "Bitlocker is enabled on {0} but the encryption method does not meet set requirements $OSDrive"
 try 
  {
 # Decrypt OS drive
 Invoke-UnEncryption
 
 # Wait for decryption to finish 
 Do 
    {
 Start-Sleep -Seconds 30
    }
 until ((Get-BitLockerVolume).VolumeStatus -eq 'FullyDecrypted')
 Write-Output "has been fully decrypted $OSDrive"

 # Check for and remove any remaining recovery password protectors
 if (Test-RecoveryPasswordProtector) 
    {
 try 
      {
 Write-Output "Recovery password protector found post decryption. Removing to prevent duplicate entries"
 Remove-RecoveryPasswordProtectors
      }
 catch 
      {
 throw $_
      }
    }

 # Check for and remaining TPM protector
 if (Test-TpmProtector) 
    {
 try 
      {
 Write-Output "TPM protector found post decryption. Removing to prevent encryption issues"
 Remove-TPMProtector
      }
 catch 
      {
 throw $_
      }
    }

 # Trigger encryption with specified encryption method 
 Invoke-Encryption
 Start-Sleep -Seconds 5
  }
 catch 
  {
 throw Write-Output "Failed on encrypting {0} after decryption $OSDrive"
  }
}

# Drive is not FullyDecrypted
elseif ((Get-BitLockerVolume).VolumeStatus -eq 'FullyDecrypted') 
{
 Write-Output "BitLocker is not enabled on $OSDrive"
 try 
  {
 # Check for and remove any remaining recovery password protectors
 if (Test-RecoveryPasswordProtector) 
    {
 try 
      {
 Write-Output "Recovery password protector found pre encryption. Removing to prevent duplicate entries"
 Remove-RecoveryPasswordProtectors
      }
 catch 
      {
 throw $_
      }
    }

 # Check for and remaining TPM protector
 if (Test-TpmProtector) 
    {
 try 
      {
 Write-Output "TPM protector found pre encryption. Removing to prevent encryption issues"
 Remove-TPMProtector
      }
 catch 
      {
 throw $_
      }
    }

 # Encrypt OS Drive with parameter $encryption_strength
 Invoke-Encryption
  }
 catch 
  {
 throw Write-Output "Error thrown encrypting $OSDrive"
  }
}

# Test for Recovery Password Protector. If not found, add Recovery Password Protector
if (-not(Test-RecoveryPasswordProtector)) 
{
 try 
  {
 Set-RecoveryPasswordProtector
  }
 catch 
  {
 throw $_
  }
}

# Test for TPM Protector. If not found, add TPM Protector
if (-not(Test-TpmProtector)) 
{
 try 
  {
 Set-TpmProtector
  }
 catch 
  {
 throw $_
  }
 Write-Output "TPM and Recovery Password protectors are present"
}

# Finally backup the Recovery Password to Azure AD
try 
{
 Backup-RecoveryPasswordProtector
}
catch 
{
 throw $_
}

Write-Output "Script complete "

#endregion MainCode
