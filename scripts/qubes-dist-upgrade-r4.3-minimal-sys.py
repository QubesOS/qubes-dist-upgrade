#!/usr/bin/python3

import qubesadmin
from qubesadmin.device_protocol import DeviceCategory

def main():
    app = qubesadmin.Qubes()
    for vm in app.domains:
        for ass in vm.devices["pci"].get_assigned_devices():
            if ass.device.interfaces[0].category == DeviceCategory.PCI_USB:
                if vm.features.check_with_template("supported-service.minimal-usbvm"):
                    print(f"Enabling minimal-usbvm for {vm.name}")
                    vm.features["service.minimal-usbvm"] = 1
            if ass.device.interfaces[0].category == DeviceCategory.Network:
                if vm.features.check_with_template("supported-service.minimal-netvm"):
                    print(f"Enabling minimal-netvm for {vm.name}")
                    vm.features["service.minimal-netvm"] = 1


if __name__ == "__main__":
    main()
