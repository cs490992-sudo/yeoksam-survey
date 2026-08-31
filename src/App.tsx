import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { AuthProvider } from './context/AuthContext'
import { AdminRoute, ProtectedRoute } from './components/ProtectedRoute'
import { AppShell } from './components/AppShell'
import { LoginPage } from './pages/LoginPage'
import { ClientPhotos, Completion, Dashboard, NewSurvey, NotFound, Reports, Search, SurveyList } from './pages/Pages'
import { PrintReportPage } from './pages/PrintReportPage'
import { SurveyEditor } from './pages/SurveyEditor'
import { SurveyRunPage } from './pages/SurveyRunPage'

export default function App() {
  return <BrowserRouter><AuthProvider><Routes>
    <Route path="/login" element={<LoginPage />} />
    <Route element={<ProtectedRoute />}><Route element={<AppShell />}>
      <Route index element={<Dashboard />} /><Route path="/admin/new" element={<SurveyEditor />} />
      <Route path="/surveys" element={<SurveyList />} /><Route path="/surveys/:surveyId/edit" element={<SurveyEditor />} /><Route path="/surveys/run" element={<SurveyRunPage />} /><Route path="/surveys/run/:surveyId/:roundId" element={<SurveyRunPage />} /><Route path="/surveys/run/:surveyId/:roundId/:clientId" element={<SurveyRunPage />} />
      <Route path="/surveys/completion" element={<Completion />} /><Route path="/surveys/:surveyId/completion" element={<Completion />} /><Route path="/surveys/search" element={<Search />} />
      <Route path="/reports" element={<Reports />} /><Route path="/reports/:surveyId" element={<Reports />} /><Route path="/reports/print" element={<PrintReportPage />} /><Route path="/reports/:surveyId/print" element={<PrintReportPage />} />
      <Route element={<AdminRoute />}><Route path="/admin/client-photos" element={<ClientPhotos />} /></Route>
      <Route path="*" element={<NotFound />} />
    </Route></Route>
  </Routes></AuthProvider></BrowserRouter>
}
