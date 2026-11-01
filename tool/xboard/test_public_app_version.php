<?php

namespace App\Http\Controllers\V1\Client {
    function admin_setting($key, $default = null) {
        return $GLOBALS['app_version_fixture'][$key] ?? $default;
    }
}

namespace App\Http\Controllers\V2\Client {
    function admin_setting($key, $default = null) {
        return $GLOBALS['app_version_fixture'][$key] ?? $default;
    }
}

namespace App\Helpers {
    function response() {
        return new class {
            public function json($data, $status) {
                return new \Illuminate\Http\JsonResponse($data, $status);
            }
        };
    }
}

namespace {
    require '/www/vendor/autoload.php';

    function check($condition, $message) {
        if (!$condition) {
            throw new \RuntimeException($message);
        }
    }

    $GLOBALS['app_version_fixture'] = [
        'windows_version' => '6.0.3',
        'windows_download_url' => 'https://github.com/YIYI-16/Haoze-Connect/releases/download/v6.0.3/HaozeConnect-Windows-Setup-x64-6.0.3.exe',
        'macos_version' => null,
        'macos_download_url' => null,
        'android_version' => '6.0.3',
        'android_download_url' => 'https://github.com/YIYI-16/Haoze-Connect/releases/download/v6.0.3/HaozeConnect-Android-arm64-6.0.3.apk',
    ];
    $container = new \Illuminate\Container\Container();
    \Illuminate\Container\Container::setInstance($container);
    $router = new \Illuminate\Routing\Router(new \Illuminate\Events\Dispatcher($container), $container);
    $router->aliasMiddleware('client', \App\Http\Middleware\Client::class);

    foreach (['V1', 'V2'] as $version) {
        $router->group(['prefix' => '/api/' . strtolower($version)], function ($router) use ($version) {
            $class = 'App\\Http\\Routes\\' . $version . '\\ClientRoute';
            (new $class())->map($router);
        });
    }

    foreach (['v1', 'v2'] as $version) {
        $request = \Illuminate\Http\Request::create('/api/' . $version . '/client/app/getVersion');
        $request->headers->set('User-Agent', 'Haoze-Connect-Updater');
        $container->instance(\Illuminate\Http\Request::class, $request);
        $route = $router->getRoutes()->match($request);
        check(!in_array('client', $route->gatherMiddleware(), true), 'Version route still requires client credentials');
        $response = $router->dispatch($request);
        check($response->getStatusCode() === 200, 'Anonymous version request failed');
        $json = json_decode($response->getContent(), true, 512, JSON_THROW_ON_ERROR);
        check($json['status'] === 'success', 'Version response is not successful');
        check($json['data'] === $GLOBALS['app_version_fixture'], 'Version response changed or exposed other settings');
        echo 'PASS anonymous ' . $version . ' version settings' . PHP_EOL;
    }

    foreach (['v1/client/subscribe', 'v1/client/app/getConfig', 'v2/client/app/getConfig'] as $path) {
        $request = \Illuminate\Http\Request::create('/api/' . $path);
        $container->instance(\Illuminate\Http\Request::class, $request);
        $route = $router->getRoutes()->match($request);
        check(in_array('client', $route->gatherMiddleware(), true), 'Protected route lost client authentication');
        try {
            $router->dispatch($request);
            throw new \RuntimeException('Protected route allowed anonymous access');
        } catch (\App\Exceptions\ApiException $error) {
            check($error->getCode() === 403, 'Unexpected protected route status');
        }
        echo 'PASS protected ' . $path . PHP_EOL;
    }
}
