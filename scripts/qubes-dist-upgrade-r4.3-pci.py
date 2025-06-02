#!/usr/bin/python3

import qubesadmin
from qubesadmin.device_protocol import DeviceCategory

def main():
    app = qubesadmin.Qubes()
    for vm in app.domains:
        for ass in vm.devices["pci"].get_assigned_devices():
            if ass.device_id != "*":
                continue
            print(f"Storing device id for {ass.port_id} ({vm.name})")
            new_ass = ass.clone(device=ass.device)
            vm.devices["pci"].unassign(ass)
            vm.devices["pci"].assign(new_ass)


if __name__ == "__main__":
    main()
