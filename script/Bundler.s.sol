import { Bundler } from "src/Bundler.sol";
import { Script, console } from "forge-std/Script.sol";

contract BundlerDeployer is Script {
    function run() public {
        address payable airlock = payable(0xe7dfbd5b0A2C3B4464653A9beCdc489229eF090E);
        address payable router = payable(0x95273d871c8156636e114b63797d78D7E1720d81);
        address quoter = 0xC5290058841028F1614F3A6F0F5816cAd0df5E27;

        vm.startBroadcast();
        Bundler bundler = new Bundler(airlock, router, quoter);

        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Contract Name              | Address                                    |");
        console.log("+----------------------------+--------------------------------------------+");
        console.log("| Bundler                    | %s |", address(bundler));
        console.log("+----------------------------+--------------------------------------------+");
        vm.stopBroadcast();
    }
}
