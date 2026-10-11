<script>
(()=>{let theme,locale;try{theme=localStorage.getItem('charm.theme');locale=localStorage.getItem('charm.locale')}catch(e){}locale=locale||document.cookie.match(/(?:^|; )charm_locale=(en|zh_CN)(?:;|$)/)?.[1];document.documentElement.dataset.theme=theme==='light'||theme==='dark'?theme:(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');document.documentElement.lang=locale==='zh_CN'?'zh-CN':'en';})();
</script>
<meta name="csrf-token" content="{{ csrf_token() }}">
@if($loginStyles ?? false)<link rel="stylesheet" href="{{ asset('login.css') }}">@endif
<link rel="stylesheet" href="{{ asset('workspace.css') }}">
<script>window.Charm={locale:document.documentElement.lang==='zh-CN'?'zh_CN':'en',userId:{{ auth()->id() ?? 'null' }},role:{{ Illuminate\Support\Js::from(auth()->user()?->role) }}};</script>
<script defer src="{{ asset('translations.js') }}"></script>
<script defer src="{{ asset('preferences.js') }}"></script>
