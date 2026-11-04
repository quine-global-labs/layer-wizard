# Built by packaging/build-flutter-rpm.sh from Flutter's release bundle; not
# a from-source spec (no %prep/%build).
%global debug_package %{nil}
# The bundle's own libraries (libflutter_linux_gtk.so, plugins) are private,
# and the executable links them from its own lib/, so no automatic
# dependencies from the bundle: the Requires below are what it needs from the
# system (the image build checks every library resolves).
%global __provides_exclude_from ^%{_libexecdir}/%{name}/.*$
%global __requires_exclude_from ^%{_libexecdir}/%{name}/.*$

Name:           layer-wizard
Version:        %{version_}
Release:        %{release_}%{?dist}
Summary:        Layer an RPM onto a bootc system, with a guided reboot and rollback
License:        LicenseRef-Not-Specified
URL:            https://forge.quinefoundation.com/quine-global-labs/layer-wizard
ExclusiveArch:  x86_64 aarch64

Requires:       gtk3
Requires:       polkit
Requires:       rpm-ostree
Requires:       bootc
Requires:       sqlite-libs

%description
A GUI wizard for permanently layering an RPM package onto an image-based
(bootc) system with rpm-ostree install, then rebooting into it and offering a
one-click rollback if the result looks wrong.

%install
mkdir -p %{buildroot}%{_libexecdir}/%{name} %{buildroot}%{_bindir}
cp -a %{bundle}/. %{buildroot}%{_libexecdir}/%{name}/
ln -s ../libexec/%{name}/layer_wizard %{buildroot}%{_bindir}/%{name}
mkdir -p %{buildroot}%{_datadir}/applications
cat > %{buildroot}%{_datadir}/applications/com.ironmagma.layer_wizard.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Layer Wizard
Comment=Permanently add a package to the system, with rollback
Exec=layer-wizard
Icon=system-software-install
Categories=System;PackageManager;
StartupWMClass=com.ironmagma.layer_wizard
DESKTOP
desktop-file-validate %{buildroot}%{_datadir}/applications/com.ironmagma.layer_wizard.desktop

%files
%{_libexecdir}/%{name}
%{_bindir}/%{name}
%{_datadir}/applications/com.ironmagma.layer_wizard.desktop
