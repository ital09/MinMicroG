# Functions for use by resdl updater

# Extract maps jar from release zip
unzipmaps() {

  mapsfile="system/framework/com.google.android.maps";

  [ -f "$resdldir/$mapsfile.zip" ] || return 0;

  echo " ";
  echo " - Unzipping maps JAR...";

  rm -rf "$resdldir/$mapsfile.jar";
  unzip -oq -j "$resdldir/$mapsfile.zip" "$mapsfile.jar" -d "$resdldir/$(dirname "$mapsfile")/";
  rm -rf "$resdldir/$mapsfile.zip";

}

# Get update delta
updatedelta() {

  newlog="";
  oldlogs="";
  loglist="$(find -L "$reldir" -type f -name "update-*.log" -exec expr {} : ".*/update-\([0-9]\{14\}\)\.log$" ';' | sort -nr)";
  for log in $loglist; do
    [ "$log" = "$updatetime" ] && newlog="$log" || oldlogs="$oldlogs $log";
  done;
  [ "$newlog" ] && [ "$oldlogs" ] || return 0;

  echo " ";
  echo " - Checking resdl delta between updates...";

  grep -oE "FILE: [^,;]*" "$reldir/update-$newlog.log" | cut -d" " -f2 | while read -r entry; do
    file="$entry";
    line="$(grep "FILE: $file[,;]" "$reldir/update-$newlog.log" | head -n1)";
    url="$(echo "$line" | grep -oE "URL: [^,;]*" | cut -d" " -f2)";
    cksum="$(echo "$line" | grep -oE "CKSUM: [^,;]*" | cut -d" " -f2)";
    oldline="";
    for log in $oldlogs; do
      oldline="$(grep "FILE: $file[,;]" "$reldir/update-$log.log" | head -n1)";
      [ "$oldline" ] && break;
    done;
    oldurl="$(echo "$oldline" | grep -oE "URL: [^,;]*" | cut -d" " -f2)";
    oldcksum="$(echo "$oldline" | grep -oE "CKSUM: [^,;]*" | cut -d" " -f2)";
    [ "$oldurl" ] || oldurl="None";
    [ "$oldcksum" ] || oldcksum="None";
    [ "$url" = "$oldurl" ] && [ "$cksum" = "$oldcksum" ] && continue;
    echo " -- Updated file: $file";
    echo "   ++ Old URL: $oldurl";
    echo "   ++ New URL: $url";
    echo "   ++ Old CKSUM: $oldcksum";
    echo "   ++ New CKSUM: $cksum";
    echo "   ++ Old name: $(basename "$oldurl")";
    echo "   ++ New name: $(basename "$url")";
  done;

}

# Verify signatures of JARs and APKs
verifycerts() {

  [ "$stuff_repo" ] || echo "$stuff_download" | grep -qE "^[ ]*[^ ]+.apk[ ]+" || return 0;

  command -v "apksigner" >/dev/null && command -v "openssl" >/dev/null || {
    echo " ";
    echo " !! Not checking certificates (missing apksigner or openssl)";
    return 0;
  }

  certdir="$resdldir/util/certs";

  echo " ";
  echo " - Checking certs for repos...";

  for repo in $(echo "$stuff_repo" | select_word 1); do
    [ -f "$tmpdir/repos/$repo.jar" ] || continue;
    certobject="repo/$repo.cer";
    apksigner verify --min-sdk-version=0 --max-sdk-version=0 "$tmpdir/repos/$repo.jar" > /dev/null || {
      echo "  !! Verification failed for repo ($repo)";
      continue;
    }
    [ -f "$certdir/$certobject" ] || {
      echo "  -- Adding cert for new repo ($repo)";
      mkdir -p "$certdir/$(dirname "$certobject")";
      unzip -p "$tmpdir/repos/$repo.jar" "META-INF/*.RSA" | openssl pkcs7 -inform der -print_certs > "$certdir/$certobject";
      continue;
    }
    unzip -p "$tmpdir/repos/$repo.jar" "META-INF/*.RSA" | openssl pkcs7 -inform der -print_certs > "$tmpdir/tmp.cer";
    [ "$(diff -w "$tmpdir/tmp.cer" "$certdir/$certobject")" ] && {
      echo "  !! Cert mismatch for repo ($repo)";
      cp -f "$tmpdir/tmp.cer" "$certdir/$certobject.new";
    }
  done;

  echo " ";
  echo " - Checking certs for APKs...";

  for object in $(echo "$stuff_download" | grep -E "^[ ]*[^ ]+.apk[ ]+" | select_word 1); do
    [ -f "$resdldir/$object" ] || continue;
    certobject="$(dirname "$object")/$(basename "$object" .apk).cer";
    apksigner verify "$resdldir/$object" > /dev/null || {
      echo "  !! Verification failed for APK ($object)";
      continue;
    }
    [ -f "$certdir/$certobject" ] || {
      echo "  -- Adding cert for new APK ($object)";
      mkdir -p "$certdir/$(dirname "$certobject")";
      unzip -p "$resdldir/$object" "META-INF/*.RSA" | openssl pkcs7 -inform der -print_certs > "$certdir/$certobject";
      continue;
    }
    unzip -p "$resdldir/$object" "META-INF/*.RSA" | openssl pkcs7 -inform der -print_certs > "$tmpdir/tmp.cer";
    [ "$(diff -w "$tmpdir/tmp.cer" "$certdir/$certobject")" ] && {
      echo "  !! Cert mismatch for APK ($object)";
      cp -f "$tmpdir/tmp.cer" "$certdir/$certobject.new";
    }
  done;

}

# Check for needed priv-perm whitelists
checkwhitelist() {

  echo "$stuff_download" | grep -qE "^[ ]*/system/priv-app/[^ ]+.apk[ ]+" || return 0;

  command -v "aapt" >/dev/null || {
    echo " ";
    echo " !! Not checking privperms (missing aapt)";
    return 0;
  }

  privpermlist="util/privperms.lst";
  privpermurl="https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/master/core/res/AndroidManifest.xml";

  echo " ";
  echo " - Getting priv-app permissions...";

  curl -fL "$privpermurl" -o "$tmpdir/tmppage" || { echo "ERROR: Android permission docpage failed to download"; return 1; }

  tr '\n' ' ' < "$tmpdir/tmppage" | grep -o '<permission [^>]*>' | grep 'android:protectionLevel="[^"]*privileged[^"]*"' | grep -o 'android:name="[^"]*"' | cut -d= -f2 | tr -d '"' > "$tmpdir/tmplist";
  echo "android.permission.FAKE_PACKAGE_SIGNATURE" >> "$tmpdir/tmplist";

  cat "$resdldir/$privpermlist" "$tmpdir/tmplist" 2>/dev/null | sort -u > "$tmpdir/sortedlist";
  mkdir -p "$resdldir/$(dirname "$privpermlist")"
  mv -f "$tmpdir/sortedlist" "$resdldir/$privpermlist";

  echo " ";
  echo " - Checking priv-app permissions...";

  find "$resdir/system/etc/permissions" -name "*.xml" -exec cat {} + | tr '\n' ' ' | sed -e 's|<privapp-permissions [^>]*>|\n&|g' -e 's|</privapp-permissions>|&\n|g' > "$tmpdir/tmpexcept";
  for object in $(echo "$stuff_download" | grep -E "^[ ]*/system/priv-app/[^ ]+.apk[ ]+" | select_word 1); do
    [ -f "$resdldir/$object" ] || { echo "ERROR: Privapp $object not found"; continue; }
    privperms="";
    privapppackage="$(aapt dump badging "$resdldir/$object" | grep -oE "package: name=[^ ]*" | sed "s|'| |g" | select_word 3)"
    privappperms="$(aapt dump permissions "$resdldir/$object" | grep -oE "uses-permission: name=[^ ]*" | sed "s|'| |g" | select_word 3 | sort -u)";
    for privperm in in $privappperms; do
      grep -q "^$privperm$" "$resdldir/$privpermlist" || continue;
      grep "<privapp-permissions package=\"$privapppackage\">" "$tmpdir/tmpexcept" 2>/dev/null | grep -q "name=\"$privperm\"" && continue;
      privperms="$privperm $privperms";
    done;
    [ "$privperms" ] || continue;
    echo " ";
    echo " -- File: $object";
    echo " -- Package: $privapppackage";
    for permentry in $privperms; do
      echo "   ++ Needs whitelisting perm $permentry";
    done;
  done;

}
