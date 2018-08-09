use v6;
use Voidvault::Config;
use Voidvault::Types;
use Voidvault::Utils;
unit class Voidvault::Bootstrap;


# -----------------------------------------------------------------------------
# attributes
# -----------------------------------------------------------------------------

has Voidvault::Config:D $.config is required;


# -----------------------------------------------------------------------------
# bootstrap
# -----------------------------------------------------------------------------

method bootstrap(::?CLASS:D: --> Nil)
{
    my Bool:D $augment = $.config.augment;
    # verify root permissions
    $*USER == 0 or die('root privileges required');
    # ensure pressing Ctrl-C works
    signal(SIGINT).tap({ exit(130) });

    self!setup;
    self!mkdisk;
    self!disable-cow;
    self!voidstrap-base;
    self!configure-users;
    self!configure-sudoers;
    self!genfstab;
    self!set-hostname;
    self!configure-hosts;
    self!configure-dhcpcd;
    self!configure-dnscrypt-proxy;
    self!set-nameservers;
    self!set-locale;
    self!set-keymap;
    self!set-timezone;
    self!set-hwclock;
    self!configure-modprobe;
    self!generate-initramfs;
    self!install-bootloader;
    self!configure-zramswap;
    self!configure-sysctl;
    self!configure-nftables;
    self!configure-openssh;
    self!configure-udev;
    self!configure-hidepid;
    self!configure-securetty;
    self!configure-xorg;
    self!enable-runit-services;
    self!augment if $augment;
    self!unmount;
}


# -----------------------------------------------------------------------------
# worker functions
# -----------------------------------------------------------------------------

method !setup(--> Nil)
{
    # rm pkgs not needed prior to voidstrap
    my Str:D @rm = qw<
        acpid
        dash
        ethtool
        f2fs-tools
        hwids
        iana-etc
        iproute2
        iputils
        ipw2100-firmware
        ipw2200-firmware
        iw
        libnl3
        libusb
        linux-firmware-amd
        linux-firmware-intel
        linux-firmware-network
        linux-firmware-nvidia
        lvm2
        man-pages
        mdadm
        mdocml
        openssh
        os-prober
        psmisc
        sudo
        traceroute
        usbutils
        void-artwork
        which
        wifi-firmware
        wpa_supplicant
        xfsprogs
        zd1211-firmware
    >;
    my Str:D $xbps-remove-cmdline =
        sprintf('xbps-remove --force-revdeps --yes %s', @rm.join(' '));
    shell($xbps-remove-cmdline);

    # fetch dependencies needed prior to voidstrap
    my Str:D @dep = qw<
        btrfs-progs
        coreutils
        cryptsetup
        dialog
        dosfstools
        e2fsprogs
        efibootmgr
        expect
        glibc
        gptfdisk
        grub
        kbd
        kmod
        libressl
        procps-ng
        tzdata
        util-linux
        xbps
    >;

    my Str:D $xbps-install-dep-cmdline =
        sprintf('xbps-install --force --sync --yes %s', @dep.join(' '));
    Voidvault::Utils.loop-cmdline-proc(
        'Installing dependencies...',
        $xbps-install-dep-cmdline
    );

    # use readable font
    run(qw<setfont Lat2-Terminus16>);
}

# secure disk configuration
method !mkdisk(--> Nil)
{
    my DiskType:D $disk-type = $.config.disk-type;
    my Str:D $partition = $.config.partition;
    my VaultName:D $vault-name = $.config.vault-name;
    my VaultPass $vault-pass = $.config.vault-pass;

    # partition disk
    sgdisk($partition);

    # create uefi partition
    mkefi($partition);

    # create vault
    mkvault($partition, $vault-name, :$vault-pass);

    # create and mount btrfs volumes
    mkbtrfs($disk-type, $vault-name);

    # mount efi boot
    mount-efi($partition);
}

# partition disk with gdisk
sub sgdisk(Str:D $partition --> Nil)
{
    # erase existing partition table
    # create 2MB EF02 BIOS boot sector
    # create 100MB EF00 EFI system partition
    # create max sized partition for LUKS encrypted volume
    run(qw<
        sgdisk
        --zap-all
        --clear
        --mbrtogpt
        --new=1:0:+2M
        --typecode=1:EF02
        --new=2:0:+100M
        --typecode=2:EF00
        --new=3:0:0
        --typecode=3:8300
    >, $partition);
}

sub mkefi(Str:D $partition --> Nil)
{
    # target partition for uefi
    my Str:D $partition-efi = sprintf(Q{%s2}, $partition);
    run(qw<modprobe vfat>);
    run(qqw<mkfs.vfat -F 32 $partition-efi>);
}

# create vault with cryptsetup
sub mkvault(
    Str:D $partition,
    VaultName:D $vault-name,
    VaultPass :$vault-pass
    --> Nil
)
{
    # target partition for vault
    my Str:D $partition-vault = sprintf(Q{%s3}, $partition);

    # load kernel modules for cryptsetup
    run(qw<modprobe dm_mod dm-crypt>);

    mkvault-cryptsetup(:$partition-vault, :$vault-name, :$vault-pass);
}

# LUKS encrypted volume password was given
multi sub mkvault-cryptsetup(
    Str:D :$partition-vault where .so,
    VaultName:D :$vault-name where .so,
    VaultPass:D :$vault-pass where .so
    --> Nil
)
{
    my Str:D $cryptsetup-luks-format-cmdline =
        build-cryptsetup-luks-format-cmdline(
            :non-interactive,
            $partition-vault,
            $vault-pass
        );

    my Str:D $cryptsetup-luks-open-cmdline =
        build-cryptsetup-luks-open-cmdline(
            :non-interactive,
            $partition-vault,
            $vault-name,
            $vault-pass
        );

    # make LUKS encrypted volume without prompt for vault password
    shell($cryptsetup-luks-format-cmdline);

    # open vault without prompt for vault password
    shell($cryptsetup-luks-open-cmdline);
}

# LUKS encrypted volume password not given
multi sub mkvault-cryptsetup(
    Str:D :$partition-vault where .so,
    VaultName:D :$vault-name where .so,
    VaultPass :vault-pass($)
    --> Nil
)
{
    my Str:D $cryptsetup-luks-format-cmdline =
        build-cryptsetup-luks-format-cmdline(
            :interactive,
            $partition-vault
        );

    my Str:D $cryptsetup-luks-open-cmdline =
        build-cryptsetup-luks-open-cmdline(
            :interactive,
            $partition-vault,
            $vault-name
        );

    # create LUKS encrypted volume, prompt user for vault password
    Voidvault::Utils.loop-cmdline-proc(
        'Creating LUKS vault...',
        $cryptsetup-luks-format-cmdline
    );

    # open LUKS encrypted volume, prompt user for vault password
    Voidvault::Utils.loop-cmdline-proc(
        'Opening LUKS vault...',
        $cryptsetup-luks-open-cmdline
    );
}

multi sub build-cryptsetup-luks-format-cmdline(
    Str:D $partition-vault where .so,
    Bool:D :interactive($) where .so
    --> Str:D
)
{
    my Str:D $spawn-cryptsetup-luks-format = qqw<
         spawn cryptsetup
         --cipher aes-xts-plain64
         --key-size 512
         --hash sha512
         --iter-time 5000
         --use-random
         --verify-passphrase
         luksFormat $partition-vault
    >.join(' ');
    my Str:D $expect-are-you-sure-send-yes =
        'expect "Are you sure*" { send "YES\r" }';
    my Str:D $interact =
        'interact';
    my Str:D $catch-wait-result =
        'catch wait result';
    my Str:D $exit-lindex-result =
        'exit [lindex $result 3]';

    my Str:D @cryptsetup-luks-format-cmdline =
        $spawn-cryptsetup-luks-format,
        $expect-are-you-sure-send-yes,
        $interact,
        $catch-wait-result,
        $exit-lindex-result;

    my Str:D $cryptsetup-luks-format-cmdline =
        sprintf(q:to/EOF/.trim, |@cryptsetup-luks-format-cmdline);
        expect -c '%s;
                   %s;
                   %s;
                   %s;
                   %s'
        EOF
}

multi sub build-cryptsetup-luks-format-cmdline(
    Str:D $partition-vault where .so,
    VaultPass:D $vault-pass where .so,
    Bool:D :non-interactive($) where .so
    --> Str:D
)
{
    my Str:D $spawn-cryptsetup-luks-format = qqw<
                 spawn cryptsetup
                 --cipher aes-xts-plain64
                 --key-size 512
                 --hash sha512
                 --iter-time 5000
                 --use-random
                 --verify-passphrase
                 luksFormat $partition-vault
    >.join(' ');
    my Str:D $sleep =
                'sleep 0.33';
    my Str:D $expect-are-you-sure-send-yes =
                'expect "Are you sure*" { send "YES\r" }';
    my Str:D $expect-enter-send-vault-pass =
        sprintf('expect "Enter*" { send "%s\r" }', $vault-pass);
    my Str:D $expect-verify-send-vault-pass =
        sprintf('expect "Verify*" { send "%s\r" }', $vault-pass);
    my Str:D $expect-eof =
                'expect eof';

    my Str:D @cryptsetup-luks-format-cmdline =
        $spawn-cryptsetup-luks-format,
        $sleep,
        $expect-are-you-sure-send-yes,
        $sleep,
        $expect-enter-send-vault-pass,
        $sleep,
        $expect-verify-send-vault-pass,
        $sleep,
        $expect-eof;

    my Str:D $cryptsetup-luks-format-cmdline =
        sprintf(q:to/EOF/.trim, |@cryptsetup-luks-format-cmdline);
        expect <<EOS
          %s
          %s
          %s
          %s
          %s
          %s
          %s
          %s
          %s
        EOS
        EOF
}

multi sub build-cryptsetup-luks-open-cmdline(
    Str:D $partition-vault where .so,
    VaultName:D $vault-name where .so,
    Bool:D :interactive($) where .so
    --> Str:D
)
{
    my Str:D $cryptsetup-luks-open-cmdline =
        "cryptsetup luksOpen $partition-vault $vault-name";
}

multi sub build-cryptsetup-luks-open-cmdline(
    Str:D $partition-vault where .so,
    VaultName:D $vault-name where .so,
    VaultPass:D $vault-pass where .so,
    Bool:D :non-interactive($) where .so
    --> Str:D
)
{
    my Str:D $spawn-cryptsetup-luks-open =
                "spawn cryptsetup luksOpen $partition-vault $vault-name";
    my Str:D $sleep =
                'sleep 0.33';
    my Str:D $expect-enter-send-vault-pass =
        sprintf('expect "Enter*" { send "%s\r" }', $vault-pass);
    my Str:D $expect-eof =
                'expect eof';

    my Str:D @cryptsetup-luks-open-cmdline =
        $spawn-cryptsetup-luks-open,
        $sleep,
        $expect-enter-send-vault-pass,
        $sleep,
        $expect-eof;

    my Str:D $cryptsetup-luks-open-cmdline =
        sprintf(q:to/EOF/.trim, |@cryptsetup-luks-open-cmdline);
        expect <<EOS
          %s
          %s
          %s
          %s
          %s
        EOS
        EOF
}

# create and mount btrfs volumes on open vault
sub mkbtrfs(DiskType:D $disk-type, VaultName:D $vault-name --> Nil)
{
    # create btrfs filesystem on opened vault
    run(qw<modprobe btrfs>);
    run(qqw<mkfs.btrfs /dev/mapper/$vault-name>);

    # set mount options
    my Str:D $mount-options = 'rw,lazytime,compress=lzo,space_cache';
    $mount-options ~= ',ssd' if $disk-type eq 'SSD';

    # mount main btrfs filesystem on open vault
    mkdir('/mnt2');
    run(qqw<mount -t btrfs -o $mount-options /dev/mapper/$vault-name /mnt2>);

    # btrfs subvolumes, starting with root / ('')
    my Str:D @btrfs-dir =
        '',
        'boot',
        'home',
        'opt',
        'srv',
        'usr',
        'var',
        'var-cache-xbps',
        'var-log',
        'var-opt',
        'var-spool',
        'var-tmp';

    # create btrfs subvolumes
    chdir('/mnt2');
    @btrfs-dir.map(-> Str:D $btrfs-dir {
        run(qqw<btrfs subvolume create @$btrfs-dir>);
    });
    chdir('/');

    # mount btrfs subvolumes
    @btrfs-dir.map(-> Str:D $btrfs-dir {
        mount-btrfs-subvolume($btrfs-dir, $mount-options, $vault-name);
    });

    # unmount /mnt2 and remove
    run(qw<umount /mnt2>);
    rmdir('/mnt2');
}

multi sub mount-btrfs-subvolume(
    'srv',
    Str:D $mount-options,
    VaultName:D $vault-name
    --> Nil
)
{
    my Str:D $btrfs-dir = 'srv';
    mkdir("/mnt/$btrfs-dir");
    run(qqw<
        mount
        -t btrfs
        -o $mount-options,nodev,noexec,nosuid,subvol=@$btrfs-dir
        /dev/mapper/$vault-name
        /mnt/$btrfs-dir
    >);
}

multi sub mount-btrfs-subvolume(
    'var-cache-xbps',
    Str:D $mount-options,
    VaultName:D $vault-name
    --> Nil
)
{
    my Str:D $btrfs-dir = 'var/cache/xbps';
    mkdir("/mnt/$btrfs-dir");
    run(qqw<
        mount
        -t btrfs
        -o $mount-options,subvol=@var-cache-xbps
        /dev/mapper/$vault-name
        /mnt/$btrfs-dir
    >);
}

multi sub mount-btrfs-subvolume(
    'var-log',
    Str:D $mount-options,
    VaultName:D $vault-name
    --> Nil
)
{
    my Str:D $btrfs-dir = 'var/log';
    mkdir("/mnt/$btrfs-dir");
    run(qqw<
        mount
        -t btrfs
        -o $mount-options,nodev,noexec,nosuid,subvol=@var-log
        /dev/mapper/$vault-name
        /mnt/$btrfs-dir
    >);
}

multi sub mount-btrfs-subvolume(
    'var-opt',
    Str:D $mount-options,
    VaultName:D $vault-name
    --> Nil
)
{
    my Str:D $btrfs-dir = 'var/opt';
    mkdir("/mnt/$btrfs-dir");
    run(qqw<
        mount
        -t btrfs
        -o $mount-options,subvol=@var-opt
        /dev/mapper/$vault-name
        /mnt/$btrfs-dir
    >);
}

multi sub mount-btrfs-subvolume(
    'var-spool',
    Str:D $mount-options,
    VaultName:D $vault-name
    --> Nil
)
{
    my Str:D $btrfs-dir = 'var/spool';
    mkdir("/mnt/$btrfs-dir");
    run(qqw<
        mount
        -t btrfs
        -o $mount-options,nodev,noexec,nosuid,subvol=@var-spool
        /dev/mapper/$vault-name
        /mnt/$btrfs-dir
    >);
}

multi sub mount-btrfs-subvolume(
    'var-tmp',
    Str:D $mount-options,
    VaultName:D $vault-name
    --> Nil
)
{
    my Str:D $btrfs-dir = 'var/tmp';
    mkdir("/mnt/$btrfs-dir");
    run(qqw<
        mount
        -t btrfs
        -o $mount-options,nodev,noexec,nosuid,subvol=@var-tmp
        /dev/mapper/$vault-name
        /mnt/$btrfs-dir
    >);
    run(qqw<chmod 1777 /mnt/$btrfs-dir>);
}

multi sub mount-btrfs-subvolume(
    Str:D $btrfs-dir,
    Str:D $mount-options,
    VaultName:D $vault-name
    --> Nil
)
{
    mkdir("/mnt/$btrfs-dir");
    run(qqw<
        mount
        -t btrfs
        -o $mount-options,subvol=@$btrfs-dir
        /dev/mapper/$vault-name
        /mnt/$btrfs-dir
    >);
}

sub mount-efi(Str:D $partition --> Nil)
{
    # target partition for uefi
    my Str:D $partition-efi = sprintf(Q{%s2}, $partition);
    my Str:D $efi-dir = '/mnt/boot/efi';
    mkdir($efi-dir);
    run(qqw<mount $partition-efi $efi-dir>);
}

method !disable-cow(--> Nil)
{
    my Str:D @directory = qw<
        home
        srv
        var/log
        var/spool
        var/tmp
    >.map(-> Str:D $directory { sprintf(Q{/mnt/%s}, $directory) });
    Voidvault::Utils.disable-cow(|@directory, :recursive);
}

# bootstrap initial chroot with voidstrap
method !voidstrap-base(--> Nil)
{
    my Processor:D $processor = $.config.processor;

    my Str:D @core = qw<
        base-system
        grub
    >;

    # download and install core packages with voidstrap in chroot
    voidstrap('/mnt', @core);

    # base packages
    my Str:D @pkg = qw<
        acpi
        autoconf
        automake
        bash
        bash-completion
        bc
        binutils
        bison
        btrfs-progs
        bzip2
        ca-certificates
        chrony
        coreutils
        crda
        cronie
        cryptsetup
        curl
        device-mapper
        dhclient
        dhcpcd
        dialog
        diffutils
        dnscrypt-proxy
        dosfstools
        dracut
        e2fsprogs
        ed
        efibootmgr
        ethtool
        exfat-utils
        expect
        file
        findutils
        flex
        gawk
        gcc
        gettext
        git
        glibc
        gnupg2
        gptfdisk
        grep
        groff
        gzip
        haveged
        inetutils
        iproute2
        iputils
        iw
        kbd
        kmod
        ldns
        less
        libressl
        libtool
        linux
        linux-firmware
        linux-firmware-network
        logrotate
        lz4
        m4
        make
        man-db
        man-pages
        mlocate
        net-tools
        nftables
        openresolv
        openssh
        patch
        pciutils
        perl
        pinentry
        pkgconf
        procps-ng
        psmisc
        rakudo
        rsync
        runit-void
        sed
        shadow
        socat
        socklog-void
        sudo
        sysfsutils
        tar
        texinfo
        tmux
        tzdata
        unzip
        usb-modeswitch
        usbutils
        util-linux
        vim
        wget
        which
        wireless_tools
        wpa_actiond
        wpa_supplicant
        xbps
        xtools
        xz
        zip
        zlib
        zstd
    >;

    # https://www.archlinux.org/news/changes-to-intel-microcodeupdates/
    push(@pkg, 'intel-ucode') if $processor eq 'intel';

    # install pkgs
    my Str:D $xbps-install-pkg-cmdline =
        sprintf('xbps-install --force --sync --yes %s', @pkg.join(' '));
    void-chroot('/mnt', $xbps-install-pkg-cmdline);
}

# secure user configuration
method !configure-users(--> Nil)
{
    my UserName:D $user-name-admin = $.config.user-name-admin;
    my UserName:D $user-name-guest = $.config.user-name-guest;
    my UserName:D $user-name-sftp = $.config.user-name-sftp;
    my Str:D $user-pass-hash-admin = $.config.user-pass-hash-admin;
    my Str:D $user-pass-hash-guest = $.config.user-pass-hash-guest;
    my Str:D $user-pass-hash-root = $.config.user-pass-hash-root;
    my Str:D $user-pass-hash-sftp = $.config.user-pass-hash-sftp;
    configure-users('root', $user-pass-hash-root);
    configure-users('admin', $user-name-admin, $user-pass-hash-admin);
    configure-users('guest', $user-name-guest, $user-pass-hash-guest);
    configure-users('sftp', $user-name-sftp, $user-pass-hash-sftp);
}

multi sub configure-users(
    'admin',
    UserName:D $user-name-admin,
    Str:D $user-pass-hash-admin
    --> Nil
)
{
    useradd('admin', $user-name-admin, $user-pass-hash-admin);
    mksudo($user-name-admin);
}

multi sub configure-users(
    'guest',
    UserName:D $user-name-guest,
    Str:D $user-pass-hash-guest
    --> Nil
)
{
    useradd('guest', $user-name-guest, $user-pass-hash-guest);
}

multi sub configure-users(
    'root',
    Str:D $user-pass-hash-root
    --> Nil
)
{
    usermod('root', $user-pass-hash-root);
}

multi sub configure-users(
    'sftp',
    UserName:D $user-name-sftp,
    Str:D $user-pass-hash-sftp
    --> Nil
)
{
    useradd('sftp', $user-name-sftp, $user-pass-hash-sftp);
}

multi sub useradd(
    'admin',
    UserName:D $user-name-admin,
    Str:D $user-pass-hash-admin
    --> Nil
)
{
    groupadd(:system, 'proc');
    my Str:D $user-group-admin = qw<
        audio
        cdrom
        floppy
        input
        kvm
        lp
        mail
        network
        optical
        proc
        scanner
        socklog
        storage
        users
        video
        wheel
        xbuilder
    >.join(',');
    my Str:D $user-shell-admin = '/bin/bash';

    say("Creating new admin user named $user-name-admin...");
    groupadd($user-name-admin);
    void-chroot(
        '/mnt',
        qqw<
            useradd
            -m
            -g $user-name-admin
            -G $user-group-admin
            -p $user-pass-hash-admin
            -s $user-shell-admin
            $user-name-admin
        >
    );
    chmod(0o700, "/mnt/home/$user-name-admin");
}

multi sub useradd(
    'guest',
    UserName:D $user-name-guest,
    Str:D $user-pass-hash-guest
    --> Nil
)
{
    my Str:D $user-group-guest = 'guests,users';
    my Str:D $user-shell-guest = '/bin/bash';

    say("Creating new guest user named $user-name-guest...");
    groupadd($user-name-guest, 'guests');
    void-chroot(
        '/mnt',
        qqw<
            useradd
            -m
            -g $user-name-guest
            -G $user-group-guest
            -p $user-pass-hash-guest
            -s $user-shell-guest
            $user-name-guest
        >
    );
    chmod(0o700, "/mnt/home/$user-name-guest");
}

multi sub useradd(
    'sftp',
    UserName:D $user-name-sftp,
    Str:D $user-pass-hash-sftp
    --> Nil
)
{
    # https://wiki.archlinux.org/index.php/SFTP_chroot
    my Str:D $user-group-sftp = 'sftponly';
    my Str:D $user-shell-sftp = '/sbin/nologin';
    my Str:D $auth-dir = '/etc/ssh/authorized_keys';
    my Str:D $jail-dir = '/srv/ssh/jail';
    my Str:D $home-dir = "$jail-dir/$user-name-sftp";
    my Str:D @root-dir = $auth-dir, $jail-dir;

    say("Creating new SFTP user named $user-name-sftp...");
    void-chroot-mkdir(@root-dir, 'root', 'root', 0o755);
    groupadd($user-name-sftp, $user-group-sftp);
    void-chroot(
        '/mnt',
        qqw<
            useradd
            -M
            -d $home-dir
            -g $user-name-sftp
            -G $user-group-sftp
            -p $user-pass-hash-sftp
            -s $user-shell-sftp
            $user-name-sftp
        >
    );
    void-chroot-mkdir($home-dir, $user-name-sftp, $user-name-sftp, 0o700);
}

sub usermod(
    'root',
    Str:D $user-pass-hash-root
    --> Nil
)
{
    say('Updating root password...');
    void-chroot('/mnt', "usermod -p $user-pass-hash-root root");
}

multi sub groupadd(Bool:D :system($)! where .so, *@group-name --> Nil)
{
    @group-name.map(-> Str:D $group-name {
        void-chroot('/mnt', "groupadd --system $group-name");
    });
}

multi sub groupadd(*@group-name --> Nil)
{
    @group-name.map(-> Str:D $group-name {
        void-chroot('/mnt', "groupadd $group-name");
    });
}

sub mksudo(UserName:D $user-name-admin --> Nil)
{
    say("Giving sudo privileges to admin user $user-name-admin...");
    my Str:D $sudoers = qq:to/EOF/;
    $user-name-admin ALL=(ALL) ALL
    $user-name-admin ALL=(ALL) NOPASSWD: /usr/bin/reboot
    $user-name-admin ALL=(ALL) NOPASSWD: /usr/bin/shutdown
    EOF
    spurt('/mnt/etc/sudoers', "\n" ~ $sudoers, :append);
}

method !configure-sudoers(--> Nil)
{
    replace('sudoers');
}

method !genfstab(--> Nil)
{
    my Str:D $path = 'usr/bin/genfstab';
    copy(%?RESOURCES{$path}, "/$path");
    copy(%?RESOURCES{$path}, "/mnt/$path");
    shell('/usr/bin/genfstab -U -p /mnt >> /mnt/etc/fstab');
    my Str:D $tmp =
        'tmpfs /tmp tmpfs mode=1777,strictatime,nodev,nodexec,nosuid 0 0';
    spurt('/mnt/etc/fstab', $tmp ~ "\n", :append);
}

method !set-hostname(--> Nil)
{
    my HostName:D $host-name = $.config.host-name;
    spurt('/mnt/etc/hostname', $host-name ~ "\n");
}

method !configure-hosts(--> Nil)
{
    my HostName:D $host-name = $.config.host-name;
    my Str:D $path = 'etc/hosts';
    copy(%?RESOURCES{$path}, "/mnt/$path");
    my Str:D $hosts = qq:to/EOF/;
    127.0.1.1        $host-name.localdomain        $host-name
    EOF
    spurt("/mnt/$path", $hosts, :append);
}

method !configure-dhcpcd(--> Nil)
{
    my Str:D $dhcpcd = q:to/EOF/;
    # Set vendor-class-id to empty string
    vendorclassid
    EOF
    spurt('/mnt/etc/dhcpcd.conf', "\n" ~ $dhcpcd, :append);
}

method !configure-dnscrypt-proxy(--> Nil)
{
    replace('dnscrypt-proxy.toml');
}

method !set-nameservers(--> Nil)
{
    my Str:D $path = 'etc/resolv.conf.head';
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

method !set-locale(--> Nil)
{
    my Locale:D $locale = $.config.locale;
    my Str:D $locale-fallback = $locale.substr(0, 2);

    # customize /etc/locale.conf
    my Str:D $locale-conf = qq:to/EOF/;
    LANG=$locale.UTF-8
    LANGUAGE=$locale:$locale-fallback
    LC_TIME=$locale.UTF-8
    EOF
    spurt('/mnt/etc/locale.conf', $locale-conf);

    # customize /etc/default/libc-locales
    replace('libc-locales', $locale);

    # regenerate locales
    void-chroot('/mnt', 'xbps-reconfigure --force glibc-locales');
}

method !set-keymap(--> Nil)
{
    my Keymap:D $keymap = $.config.keymap;
    replace('rc.conf', 'KEYMAP', $keymap);
    replace('rc.conf', 'FONT');
    replace('rc.conf', 'FONT_MAP');
}

method !set-timezone(--> Nil)
{
    my Timezone:D $timezone = $.config.timezone;
    void-chroot('/mnt', "ln -sf /usr/share/zoneinfo/$timezone /etc/localtime");
    replace('rc.conf', 'TIMEZONE', $timezone);
}

method !set-hwclock(--> Nil)
{
    void-chroot('/mnt', 'hwclock --systohc --utc');
}

method !configure-modprobe(--> Nil)
{
    my Str:D $path = 'etc/modprobe.d/modprobe.conf';
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

method !generate-initramfs(--> Nil)
{
    my Graphics:D $graphics = $.config.graphics;
    my Processor:D $processor = $.config.processor;
    replace('dracut.conf.d', $graphics, $processor);
    my Str:D $linux-version = dir('/mnt/usr/lib/modules').first.basename;
    my Str:D $dracut-cmdline =
        sprintf(Q{dracut --kver %s}, $linux-version);
    void-chroot('/mnt', $dracut-cmdline);
    my Str:D $xbps-linux-version-raw =
        qx{xbps-query --rootdir /mnt --property pkgver linux}.trim;
    my Str:D $xbps-linux-version =
        $xbps-linux-version-raw.substr(6..*).split(/'.'|'_'/)[^2].join('.');
    my Str:D $xbps-reconfigure-linux-cmdline =
        sprintf(Q{xbps-reconfigure --force linux%s}, $xbps-linux-version);
    void-chroot('/mnt', $xbps-reconfigure-linux-cmdline);
}

method !install-bootloader(--> Nil)
{
    my Graphics:D $graphics = $.config.graphics;
    my Str:D $partition = $.config.partition;
    my UserName:D $user-name-grub = $.config.user-name-grub;
    my Str:D $user-pass-hash-grub = $.config.user-pass-hash-grub;
    my VaultName:D $vault-name = $.config.vault-name;
    replace('grub', $graphics, $partition, $vault-name);
    replace('10_linux');
    configure-bootloader('superusers', $user-name-grub, $user-pass-hash-grub);
    install-bootloader($partition);
}

sub configure-bootloader(
    'superusers',
    UserName:D $user-name-grub,
    Str:D $user-pass-hash-grub
    --> Nil
)
{
    my Str:D $grub-superusers = qq:to/EOF/;
    set superusers="$user-name-grub"
    password_pbkdf2 $user-name-grub $user-pass-hash-grub
    EOF
    spurt('/mnt/etc/grub.d/40_custom', $grub-superusers, :append);
}

multi sub install-bootloader(
    Str:D $partition
    --> Nil
)
{
    install-bootloader(:legacy, $partition);
    install-bootloader(:uefi, $partition);
    copy(
        '/mnt/usr/share/locale/en@quot/LC_MESSAGES/grub.mo',
        '/mnt/boot/grub/locale/en.mo'
    );
    void-chroot('/mnt', 'grub-mkconfig -o /boot/grub/grub.cfg');
}

multi sub install-bootloader(
    Str:D $partition,
    Bool:D :legacy($)! where .so
    --> Nil
)
{
    # legacy bios
    void-chroot(
        '/mnt',
        qqw<
            grub-install
            --target=i386-pc
            --recheck
            $partition
        >
    );
}

multi sub install-bootloader(
    Str:D $partition,
    Bool:D :uefi($)! where .so
    --> Nil
)
{
    # uefi
    void-chroot(
        '/mnt',
        qqw<
            grub-install
            --target=x86_64-efi
            --efi-directory=/boot/efi
            --removable
            $partition
        >
    );

    # fix virtualbox uefi
    my Str:D $nsh = q:to/EOF/;
    fs0:
    \EFI\BOOT\BOOTX64.EFI
    EOF
    spurt('/mnt/boot/efi/startup.nsh', $nsh, :append);
}

method !configure-zramswap(--> Nil)
{
    # install zramctrl executable
    configure-zramswap('executable');
    # install zramswap start and stop script
    configure-zramswap('run');
    configure-zramswap('control/d');
}

multi sub configure-zramswap('executable' --> Nil)
{
    my Str:D $path = 'usr/bin/zramctrl';
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

multi sub configure-zramswap('run' --> Nil)
{
    my Str:D $base-path = 'etc/sv/zramswap';
    my Str:D $path = "$base-path/run";
    mkdir("/mnt/$base-path");
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

multi sub configure-zramswap('control/d' --> Nil)
{
    my Str:D $base-path = 'etc/sv/zramswap/control';
    my Str:D $path = "$base-path/d";
    mkdir("/mnt/$base-path");
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

method !configure-sysctl(--> Nil)
{
    my DiskType:D $disk-type = $.config.disk-type;
    my Str:D $base-path = 'etc/sysctl.d';
    my Str:D $path = "$base-path/99-sysctl.conf";
    mkdir("/mnt/$base-path");
    copy(%?RESOURCES{$path}, "/mnt/$path");
    replace('99-sysctl.conf', $disk-type);
    void-chroot('/mnt', 'sysctl --system');
}

method !configure-nftables(--> Nil)
{
    # XXX: customize nftables
    Nil;
}

method !configure-openssh(--> Nil)
{
    my UserName:D $user-name-sftp = $.config.user-name-sftp;
    configure-openssh('ssh_config');
    configure-openssh('sshd_config', $user-name-sftp);
    configure-openssh('hosts.allow');
    configure-openssh('moduli');
}

multi sub configure-openssh('ssh_config' --> Nil)
{
    my Str:D $path = 'etc/ssh/ssh_config';
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

multi sub configure-openssh('sshd_config', UserName:D $user-name-sftp --> Nil)
{
    my Str:D $path = 'etc/ssh/sshd_config';
    copy(%?RESOURCES{$path}, "/mnt/$path");
    # restrict allowed connections to $user-name-sftp
    replace('sshd_config', $user-name-sftp);
}

multi sub configure-openssh('hosts.allow' --> Nil)
{
    # restrict allowed connections to LAN
    my Str:D $path = 'etc/hosts.allow';
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

multi sub configure-openssh('moduli' --> Nil)
{
    # filter weak ssh moduli
    replace('moduli');
}

method !configure-udev(--> Nil)
{
    my Str:D $base-path = 'etc/udev/rules.d';
    my Str:D $path = "$base-path/60-io-schedulers.rules";
    mkdir("/mnt/$base-path");
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

method !configure-hidepid(--> Nil)
{
    my Str:D $fstab-hidepid = q:to/EOF/;
    # /proc with hidepid (https://wiki.archlinux.org/index.php/Security#hidepid)
    proc                                      /proc       proc        nodev,noexec,nosuid,hidepid=2,gid=proc 0 0
    EOF
    spurt('/mnt/etc/fstab', $fstab-hidepid, :append);
}

method !configure-securetty(--> Nil)
{
    configure-securetty('securetty');
    configure-securetty('shell-timeout');
}

multi sub configure-securetty('securetty' --> Nil)
{
    my Str:D $path = 'etc/securetty';
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

multi sub configure-securetty('shell-timeout' --> Nil)
{
    my Str:D $path = 'etc/profile.d/shell-timeout.sh';
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

method !configure-xorg(--> Nil)
{
    configure-xorg('Xwrapper.config');
    configure-xorg('10-synaptics.conf');
    configure-xorg('99-security.conf');
}

multi sub configure-xorg('Xwrapper.config' --> Nil)
{
    my Str:D $base-path = 'etc/X11';
    my Str:D $path = "$base-path/Xwrapper.config";
    mkdir("/mnt/$base-path");
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

multi sub configure-xorg('10-synaptics.conf' --> Nil)
{
    my Str:D $base-path = 'etc/X11/xorg.conf.d';
    my Str:D $path = "$base-path/10-synaptics.conf";
    mkdir("/mnt/$base-path");
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

multi sub configure-xorg('99-security.conf' --> Nil)
{
    my Str:D $base-path = 'etc/X11/xorg.conf.d';
    my Str:D $path = "$base-path/99-security.conf";
    mkdir("/mnt/$base-path");
    copy(%?RESOURCES{$path}, "/mnt/$path");
}

method !enable-runit-services(--> Nil)
{
    my Str:D @service = qw<
        dnscrypt-proxy
        nftables
        socklog-unix
        zramswap
    >;
    @service.map(-> Str:D $service {
        run(qqw<
            ln
            -sf /etc/sv/$service
            /mnt/etc/runit/runsvdir/default/$service
        >);
    });
}

# interactive console
method !augment(--> Nil)
{
    # launch fully interactive Bash console, type 'exit' to exit
    shell('expect -c "spawn /bin/bash; interact"');
}

method !unmount(--> Nil)
{
    shell('umount -R /mnt');
    my VaultName:D $vault-name = $.config.vault-name;
    run(qqw<cryptsetup luksClose $vault-name>);
}


# -----------------------------------------------------------------------------
# helper functions
# -----------------------------------------------------------------------------

# sub voidstrap {{{

# based on arch-install-scripts v18
sub voidstrap(Str:D $chroot-dir, Str:D @pkg --> Nil)
{
    my Str:D @*chroot-active-mount;
    create-obligatory-dirs($chroot-dir);
    chroot-setup($chroot-dir);
    chroot-add-host-keys($chroot-dir);
    voidstrap-install($chroot-dir, @pkg);
    LEAVE chroot-teardown();
}

# --- sub create-obligatory-dirs {{{

multi sub create-obligatory-dirs(Str:D $chroot-dir where .IO.d.so --> Nil)
{
    mkdir("$chroot-dir/dev", 0o0755);
    mkdir("$chroot-dir/etc", 0o0755);
    mkdir("$chroot-dir/run", 0o0755);
    mkdir("$chroot-dir/var/log", 0o0755);
    run(qqw<mkdir --mode=1777 --parents $chroot-dir/tmp>);
    mkdir("$chroot-dir/proc", 0o0555);
    mkdir("$chroot-dir/sys", 0o0555);
}

multi sub create-obligatory-dirs($chroot-dir --> Nil)
{
    my Str:D $message = sprintf(Q{Sorry, %s is not a directory}, $chroot-dir);
    die($message);
}

# --- end sub create-obligatory-dirs }}}
# --- sub chroot-setup {{{

# mount API filesystems
sub chroot-setup(Str:D $chroot-dir --> Nil)
{
    chroot-add-mount(|qqw<
        proc
        $chroot-dir/proc
        --types proc
        --options nodev,noexec,nosuid
    >);
    chroot-add-mount(|qqw<
        sys
        $chroot-dir/sys
        --types sysfs
        --options nodev,noexec,nosuid,ro
    >);
    chroot-add-mount(|qqw<
        efivarfs
        $chroot-dir/sys/firmware/efi/efivars
        --types efivarfs
        --options nodev,noexec,nosuid
    >) if "$chroot-dir/sys/firmware/efi/efivars".IO.d;
    chroot-add-mount(|qqw<
        udev
        $chroot-dir/dev
        --types devtmpfs
        --options mode=0755,nosuid
    >);
    chroot-add-mount(|qqw<
        devpts
        $chroot-dir/dev/pts
        --types devpts
        --options gid=5,mode=0620,noexec,nosuid
    >);
    chroot-add-mount(|qqw<
        shm
        $chroot-dir/dev/shm
        --types tmpfs
        --options mode=1777,nodev,nosuid
    >);
    chroot-add-mount(|qqw<
        run
        $chroot-dir/run
        --types tmpfs
        --options mode=0755,nodev,nosuid
    >);
    chroot-add-mount(|qqw<
        tmp
        $chroot-dir/tmp
        --types tmpfs
        --options mode=1777,nodev,nosuid,strictatime
    >);
}

# --- end sub chroot-setup }}}
# --- sub chroot-teardown {{{

sub chroot-teardown(--> Nil)
{
    # C<umount> deeper directories first with C<.reverse>
    @*chroot-active-mount.reverse.map(-> Str:D $dir { run(qqw<umount $dir>) });
    @*chroot-active-mount = Empty;
}

# --- end sub chroot-teardown }}}
# --- sub chroot-add-mount {{{

sub chroot-add-mount(Str:D $source, Str:D $dest, *@opts --> Nil)
{
    my Str:D $mount-cmdline =
        sprintf(Q{mount %s %s %s}, $source, $dest, @opts.join(' '));
    my Proc:D $proc = shell($mount-cmdline);
    $proc.exitcode == 0
        or die('Sorry, could not add mount');
    push(@*chroot-active-mount, $dest);
}

# --- end sub chroot-add-mount }}}
# --- sub chroot-add-host-keys {{{

# copy existing host keys to the target chroot
multi sub chroot-add-host-keys(
    Str:D $chroot-dir,
    Str:D $host-keys-dir where .IO.d.so = '/var/db/xbps/keys'
    --> Nil
)
{
    my Str:D $host-keys-chroot-dir =
        sprintf(Q{%s%s}, $chroot-dir, $host-keys-dir);
    mkdir($host-keys-chroot-dir);
    shell("cp --archive $host-keys-dir/* $host-keys-chroot-dir");
}

# no existing host keys to copy
multi sub chroot-add-host-keys(
    Str:D $,
    Str:D $
    --> Nil
)
{*}

# --- end sub chroot-add-host-keys }}}
# --- sub voidstrap-install {{{

sub voidstrap-install(Str:D $chroot-dir, Str:D @pkg --> Nil)
{
    my Str:D $repository = 'https://repo.voidlinux.eu/current';
    my Str:D $xbps-install-opts =
        sprintf(
            Q{--repository %s --force --sync --yes --rootdir %s},
            $repository,
            $chroot-dir
        );
    my Str:D $xbps-install-pkg-cmdline =
        sprintf(
            Q{xbps-install %s %s},
            $xbps-install-opts,
            @pkg.join(' ')
        );
    Voidvault::Utils.loop-cmdline-proc(
        'Running voidstrap...',
        $xbps-install-pkg-cmdline
    );
}

# --- end sub voidstrap-install }}}

# end sub voidstrap }}}
# sub void-chroot {{{

multi sub void-chroot(Str:D $chroot-dir, @cmdline --> Nil)
{
    my Str:D $cmdline = @cmdline.join(' ');
    void-chroot($chroot-dir, $cmdline);
}

multi sub void-chroot(Str:D $chroot-dir, Str:D $cmdline where .so --> Nil)
{
    my Str:D @*chroot-active-mount;
    chroot-setup($chroot-dir);
    chroot-add-resolv-conf($chroot-dir);
    shell("SHELL=/bin/bash unshare --fork --pid chroot $chroot-dir $cmdline");
    LEAVE chroot-teardown();
}

# --- sub chroot-add-resolv-conf {{{

# or C<run(qqw<cp --dereference /etc/resolv.conf $chroot-dir/etc>);>
multi sub chroot-add-resolv-conf(
    Str:D $chroot-dir where '/etc/resolv.conf'.IO.e.so
    --> Nil
)
{
    run(qqw<cp --dereference /etc/resolv.conf $chroot-dir/etc>);
}

# nothing to do
multi sub chroot-add-resolv-conf(
    Str:D $
    --> Nil
)
{*}

# --- end sub chroot-add-resolv-conf }}}

# end sub void-chroot }}}
# sub void-chroot-mkdir {{{

multi sub void-chroot-mkdir(
    Str:D @dir,
    Str:D $user,
    Str:D $group,
    # permissions should be octal: https://doc.perl6.org/routine/chmod
    UInt:D $permissions
    --> Nil
)
{
    @dir.map(-> Str:D $dir {
        void-chroot-mkdir($dir, $user, $group, $permissions)
    });
}

multi sub void-chroot-mkdir(
    Str:D $dir,
    Str:D $user,
    Str:D $group,
    UInt:D $permissions
    --> Nil
)
{
    mkdir("/mnt/$dir", $permissions);
    void-chroot('/mnt', "chown $user:$group $dir");
}

# end sub void-chroot-mkdir }}}
# sub replace {{{

# --- sudoers {{{

multi sub replace(
    'sudoers'
    --> Nil
)
{
    my Str:D $file = '/mnt/etc/sudoers';
    my Str:D $slurp = slurp($file);
    my Str:D $defaults = q:to/EOF/;
    # reset environment by default
    Defaults env_reset

    # set default editor to rvim, do not allow visudo to use $EDITOR/$VISUAL
    Defaults editor=/usr/bin/rvim, !env_editor

    # force password entry with every sudo
    Defaults timestamp_timeout=0

    # only allow sudo when the user is logged in to a real tty
    Defaults requiretty

    # wrap logfile lines at 72 characters
    Defaults loglinelen=72
    EOF
    my Str:D $replace = join("\n", $defaults, $slurp);
    spurt($file, $replace);
}

# --- end sudoers }}}
# --- dnscrypt-proxy.toml {{{

multi sub replace(
    'dnscrypt-proxy.toml'
    --> Nil
)
{
    my Str:D $file = '/mnt/etc/dnscrypt-proxy.toml';
    my Str:D @replace =
        $file.IO.lines
        # server must support DNS security extensions (DNSSEC)
        ==> replace('dnscrypt-proxy.toml', 'require_dnssec')
        # always use TCP to connect to upstream servers
        ==> replace('dnscrypt-proxy.toml', 'force_tcp')
        # create new, unique key for each DNS query
        ==> replace('dnscrypt-proxy.toml', 'dnscrypt_ephemeral_keys')
        # disable TLS session tickets
        ==> replace('dnscrypt-proxy.toml', 'tls_disable_session_tickets')
        # disable DNS cache
        ==> replace('dnscrypt-proxy.toml', 'cache');
    my Str:D $replace = @replace.join("\n");
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    'dnscrypt-proxy.toml',
    Str:D $subject where 'require_dnssec',
    Str:D @line
    --> Array[Str:D]
)
{
    my UInt:D $index = @line.first(/^$subject/, :k);
    my Str:D $replace = sprintf(Q{%s = true}, $subject);
    @line[$index] = $replace;
    @line;
}

multi sub replace(
    'dnscrypt-proxy.toml',
    Str:D $subject where 'force_tcp',
    Str:D @line
    --> Array[Str:D]
)
{
    my UInt:D $index = @line.first(/^$subject/, :k);
    my Str:D $replace = sprintf(Q{%s = true}, $subject);
    @line[$index] = $replace;
    @line;
}

multi sub replace(
    'dnscrypt-proxy.toml',
    Str:D $subject where 'dnscrypt_ephemeral_keys',
    Str:D @line
    --> Array[Str:D]
)
{
    my UInt:D $index = @line.first(/^'#'\h*$subject/, :k);
    my Str:D $replace = sprintf(Q{%s = true}, $subject);
    @line[$index] = $replace;
    @line;
}

multi sub replace(
    'dnscrypt-proxy.toml',
    Str:D $subject where 'tls_disable_session_tickets',
    Str:D @line
    --> Array[Str:D]
)
{
    my UInt:D $index = @line.first(/^'#'\h*$subject/, :k);
    my Str:D $replace = sprintf(Q{%s = true}, $subject);
    @line[$index] = $replace;
    @line;
}

multi sub replace(
    'dnscrypt-proxy.toml',
    Str:D $subject where 'cache',
    Str:D @line
    --> Array[Str:D]
)
{
    my UInt:D $index = @line.first(/^$subject\h/, :k);
    my Str:D $replace = sprintf(Q{%s = false}, $subject);
    @line[$index] = $replace;
    @line;
}

# --- end dnscrypt-proxy.toml }}}
# --- libc-locales {{{

multi sub replace(
    'libc-locales',
    Locale:D $locale
    --> Nil
)
{
    my Str:D $file = '/mnt/etc/default/libc-locales';
    my Str:D @line = $file.IO.lines;
    my Str:D $locale-full = sprintf(Q{%s.UTF-8 UTF-8}, $locale);
    my UInt:D $index = @line.first(/^"#$locale-full"/, :k);
    @line[$index] = $locale-full;
    my Str:D $replace = @line.join("\n");
    spurt($file, $replace ~ "\n");
}

# --- end libc-locales }}}
# --- rc.conf {{{

multi sub replace(
    'rc.conf',
    'KEYMAP',
    Keymap:D $keymap
)
{
    my Str:D $file = '/mnt/etc/rc.conf';
    my Str:D @line = $file.IO.lines;
    my UInt:D $index = @line.first(/^'#'?KEYMAP'='/, :k);
    my Str:D $keymap-line = sprintf(Q{KEYMAP=%s}, $keymap);
    @line[$index] = $keymap-line;
    my Str:D $replace = @line.join("\n");
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    'rc.conf',
    'FONT'
)
{
    my Str:D $file = '/mnt/etc/rc.conf';
    my Str:D @line = $file.IO.lines;
    my UInt:D $index = @line.first(/^'#'?FONT'='/, :k);
    my Str:D $font-line = 'FONT=Lat2-Terminus16';
    @line[$index] = $font-line;
    my Str:D $replace = @line.join("\n");
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    'rc.conf',
    'FONT_MAP'
)
{
    my Str:D $file = '/mnt/etc/rc.conf';
    my Str:D @line = $file.IO.lines;
    my UInt:D $index = @line.first(/^'#'?FONT_MAP'='/, :k);
    my Str:D $font-map-line = 'FONT_MAP=';
    @line[$index] = $font-map-line;
    my Str:D $replace = @line.join("\n");
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    'rc.conf',
    'TIMEZONE',
    Timezone:D $timezone
)
{
    my Str:D $file = '/mnt/etc/rc.conf';
    my Str:D @line = $file.IO.lines;
    my UInt:D $index = @line.first(/^'#'?TIMEZONE'='/, :k);
    my Str:D $timezone-line = sprintf(Q{TIMEZONE=%s}, $timezone);
    @line[$index] = $timezone-line;
    my Str:D $replace = @line.join("\n");
    spurt($file, $replace ~ "\n");
}

# --- end rc.conf }}}
# --- dracut.conf.d {{{

multi sub replace(
    'dracut.conf.d',
    Graphics:D $graphics,
    Processor:D $processor
    --> Nil
)
{
    replace('dracut.conf.d', 'compress.conf');
    replace('dracut.conf.d', 'drivers.conf');
    replace('dracut.conf.d', 'modules.conf', $graphics, $processor);
    replace('dracut.conf.d', 'policy.conf');
    replace('dracut.conf.d', 'tmpdir.conf');
}

multi sub replace(
    'dracut.conf.d',
    Str:D $subject where 'compress.conf'
    --> Nil
)
{
    my Str:D $file = sprintf(Q{/etc/dracut.conf.d/%s}, $subject);
    my Str:D $replace = 'compress="zstd"';
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    'dracut.conf.d',
    Str:D $subject where 'drivers.conf'
    --> Nil
)
{
    my Str:D $file = sprintf(Q{/etc/dracut.conf.d/%s}, $subject);
    my Str:D $replace = 'add_drivers+=" ahci "';
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    'dracut.conf.d',
    Str:D $subject where 'modules.conf',
    Graphics:D $graphics,
    Processor:D $processor
    --> Nil
)
{
    my Str:D $file = sprintf(Q{/etc/dracut.conf.d/%s}, $subject);
    my Str:D @modules = qw<crypt btrfs>;
    push(@modules, $processor eq 'INTEL' ?? 'crc32c-intel' !! 'crc32c');
    push(@modules, 'i915') if $graphics eq 'INTEL';
    push(@modules, 'nouveau') if $graphics eq 'NVIDIA';
    push(@modules, 'radeon') if $graphics eq 'RADEON';
    # for zram lz4 compression
    push(@modules, |qw<lz4 lz4_compress>);
    my Str:D $replace =
        sprintf(Q{add_dracutmodules+=" %s "}, @modules.join(' '));
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    'dracut.conf.d',
    Str:D $subject where 'policy.conf'
    --> Nil
)
{
    my Str:D $file = sprintf(Q{/etc/dracut.conf.d/%s}, $subject);
    my Str:D $replace = 'persistent_policy="by-uuid"';
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    'dracut.conf.d',
    Str:D $subject where 'tmpdir.conf'
    --> Nil
)
{
    my Str:D $file = sprintf(Q{/etc/dracut.conf.d/%s}, $subject);
    my Str:D $replace = 'tmpdir="/tmp"';
    spurt($file, $replace ~ "\n");
}

# --- end dracut.conf.d }}}
# --- grub {{{

multi sub replace(
    'grub',
    *@opts (
        Graphics:D $graphics,
        Str:D $partition,
        VaultName:D $vault-name
    )
    --> Nil
)
{
    my Str:D $file = '/mnt/etc/default/grub';
    my Str:D @replace =
        $file.IO.lines
        ==> replace('grub', 'GRUB_CMDLINE_LINUX_DEFAULT', |@opts)
        ==> replace('grub', 'GRUB_ENABLE_CRYPTODISK')
        ==> replace('grub', 'GRUB_TERMINAL_INPUT')
        ==> replace('grub', 'GRUB_TERMINAL_OUTPUT');
    my Str:D $replace = @replace.join("\n");
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    'grub',
    Str:D $subject where 'GRUB_CMDLINE_LINUX_DEFAULT',
    Graphics:D $graphics,
    Str:D $partition,
    VaultName:D $vault-name,
    Str:D @line
    --> Array[Str:D]
)
{
    # prepare GRUB_CMDLINE_LINUX_DEFAULT
    my Str:D $partition-vault = sprintf(Q{%s3}, $partition);
    my Str:D $vault-uuid = qqx<blkid -s UUID -o value $partition-vault>.trim;
    my Str:D $grub-cmdline-linux =
        sprintf(
            Q{cryptdevice=/dev/disk/by-uuid/%s:%s rootflags=subvol=@},
            $vault-uuid,
            $vault-name
        );
    $grub-cmdline-linux ~= ' rd.auto=1';
    $grub-cmdline-linux ~= ' rd.luks=1';
    $grub-cmdline-linux ~= " rd.luks.uuid=$vault-uuid";
    $grub-cmdline-linux ~= ' loglevel=6';
    $grub-cmdline-linux ~= ' slub_debug=P';
    $grub-cmdline-linux ~= ' page_poison=1';
    $grub-cmdline-linux ~= ' printk.time=1';
    $grub-cmdline-linux ~= ' radeon.dpm=1' if $graphics eq 'RADEON';
    # replace GRUB_CMDLINE_LINUX_DEFAULT
    my UInt:D $index = @line.first(/^$subject'='/, :k);
    my Str:D $replace = sprintf(Q{%s="%s"}, $subject, $grub-cmdline-linux);
    @line[$index] = $replace;
    @line;
}

multi sub replace(
    'grub',
    Str:D $subject where 'GRUB_ENABLE_CRYPTODISK',
    Str:D @line
    --> Array[Str:D]
)
{
    # if C<GRUB_ENABLE_CRYPTODISK> not found, append to bottom of file
    my UInt:D $index = @line.first(/^'#'$subject/, :k) // @line.elems + 1;
    my Str:D $replace = sprintf(Q{%s=y}, $subject);
    @line[$index] = $replace;
    @line;
}

multi sub replace(
    'grub',
    Str:D $subject where 'GRUB_TERMINAL_INPUT',
    Str:D @line
    --> Array[Str:D]
)
{
    my UInt:D $index = @line.first(/^'#'?$subject/, :k) // @line.elems + 1;
    my Str:D $replace = sprintf(Q{%s="console"}, $subject);
    @line[$index] = $replace;
    @line;
}

multi sub replace(
    'grub',
    Str:D $subject where 'GRUB_TERMINAL_OUTPUT',
    Str:D @line
    --> Array[Str:D]
)
{
    my UInt:D $index = @line.first(/^'#'?$subject/, :k) // @line.elems + 1;
    my Str:D $replace = sprintf(Q{%s="console"}, $subject);
    @line[$index] = $replace;
    @line;
}

# --- end grub }}}
# --- 10_linux {{{

multi sub replace(
    '10_linux'
    --> Nil
)
{
    my Str:D $file = '/mnt/etc/grub.d/10_linux';
    my Str:D @line = $file.IO.lines;
    my Regex:D $regex = /'${CLASS}'\h/;
    my UInt:D @index = @line.grep($regex, :k);
    @index.race.map(-> UInt:D $index {
        @line[$index] .= subst($regex, '--unrestricted ${CLASS} ')
    });
    my Str:D $replace = @line.join("\n");
    spurt($file, $replace ~ "\n");
}

# --- end 10_linux }}}
# --- 99-sysctl.conf {{{

multi sub replace(
    '99-sysctl.conf',
    DiskType:D $disk-type where /SSD|USB/
    --> Nil
)
{
    my Str:D $file = '/mnt/etc/sysctl.d/99-sysctl.conf';
    my Str:D @replace =
        $file.IO.lines
        ==> replace('99-sysctl.conf', 'vm.vfs_cache_pressure')
        ==> replace('99-sysctl.conf', 'vm.swappiness');
    my Str:D $replace = @replace.join("\n");
    spurt($file, $replace ~ "\n");
}

multi sub replace(
    '99-sysctl.conf',
    DiskType:D $disk-type
    --> Nil
)
{*}

multi sub replace(
    '99-sysctl.conf',
    Str:D $subject where 'vm.vfs_cache_pressure',
    Str:D @line
    --> Array[Str:D]
)
{
    my UInt:D $index = @line.first(/^'#'$subject/, :k);
    my Str:D $replace = sprintf(Q{%s = 50}, $subject);
    @line[$index] = $replace;
    @line;
}

multi sub replace(
    '99-sysctl.conf',
    Str:D $subject where 'vm.swappiness',
    Str:D @line
    --> Array[Str:D]
)
{
    my UInt:D $index = @line.first(/^'#'$subject/, :k);
    my Str:D $replace = sprintf(Q{%s = 1}, $subject);
    @line[$index] = $replace;
    @line;
}

# --- end 99-sysctl.conf }}}
# --- sshd_config {{{

multi sub replace(
    'sshd_config',
    UserName:D $user-name-sftp
    --> Nil
)
{
    my Str:D $file = '/mnt/etc/ssh/sshd_config';
    my Str:D @line = $file.IO.lines;
    my UInt:D $index = @line.first(/^AddressFamily/, :k);
    # put AllowUsers on the line below AddressFamily
    my Str:D $allow-users = sprintf(Q{AllowUsers %s}, $user-name-sftp);
    @line.splice($index + 1, 0, $allow-users);
    my Str:D $replace = @line.join("\n");
    spurt($file, $replace ~ "\n");
}

# --- end sshd_config }}}
# --- moduli {{{

multi sub replace(
    'moduli'
    --> Nil
)
{
    my Str:D $file = '/mnt/etc/ssh/moduli';
    my Str:D $replace =
        $file.IO.lines
        .grep(/^\w/)
        .grep({ .split(/\h+/)[4] > 2000 })
        .join("\n");
    spurt($file, $replace ~ "\n");
}

# --- end moduli }}}

# end sub replace }}}

# vim: set filetype=perl6 foldmethod=marker foldlevel=0 nowrap:
