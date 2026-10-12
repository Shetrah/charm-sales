import React from 'react';
import ReactDOM from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { BrowserRouter } from 'react-router-dom';
import { PreferencesProvider } from './i18n';
import App from './App';
import './styles.css';
const queryClient=new QueryClient({defaultOptions:{queries:{staleTime:20000,retry:1,refetchOnWindowFocus:true}}});
ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><QueryClientProvider client={queryClient}><PreferencesProvider><BrowserRouter><App/></BrowserRouter></PreferencesProvider></QueryClientProvider></React.StrictMode>);
